package renderer

import "base:runtime"
import "core:c"
import "core:log"
import "core:os"
import "core:strings"
import clay "library:clay"
import sdl "vendor:sdl3"
import sdl_ttf "vendor:sdl3/ttf"

when ODIN_OS == .Darwin {
	SHADER_TYPE :: sdl.GPUShaderFormat{.MSL}
	ENTRY_POINT :: "main0"
} else {
	SHADER_TYPE :: sdl.GPUShaderFormat{.SPIRV}
	ENTRY_POINT :: "main"
}

BUFFER_INIT_SIZE: u32 : 256

dpi_scaling: f32 = 1.0
layers: [dynamic]Layer
quad_pipeline: QuadPipeline
text_pipeline: TextPipeline
odin_context: runtime.Context

// TODO New layer for each z-index/batch
Layer :: struct {
	quad_instance_start: u32,
	quad_len:            u32,
	text_instance_start: u32,
	text_instance_len:   u32,
	text_vertex_start:   u32,
	text_vertex_len:     u32,
	text_index_start:    u32,
	text_index_len:      u32,
	scissors:            [dynamic]Scissor,
}

Scissor :: struct {
	bounds:     sdl.Rect,
	quad_start: u32,
	quad_len:   u32,
	text_start: u32,
	text_len:   u32,
}

/// Initialize the renderer.
init :: proc(
	device: ^sdl.GPUDevice,
	window: ^sdl.Window,
	window_width: f32,
	window_height: f32,
	ctx: runtime.Context,
) {
	odin_context = ctx
	dpi_scaling = sdl.GetWindowDisplayScale(window)
	log.debug("Window DPI scaling:", dpi_scaling)

	min_memory_size: c.size_t = cast(c.size_t)clay.MinMemorySize()
	memory := make([^]u8, min_memory_size)
	arena := clay.CreateArenaWithCapacityAndMemory(min_memory_size, memory)

	clay.Initialize(arena, {window_width, window_height}, {handler = clay_error_handler})
	clay.SetMeasureTextFunction(measure_text, nil)
	quad_pipeline = create_quad_pipeline(device, window)
	text_pipeline = create_text_pipeline(device, window)
}

clay_error_handler :: proc "c" (errorData: clay.ErrorData) {
	context = odin_context
	log.error("Clay error:", errorData.errorType, errorData.errorText)
}

@(private = "file")
measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	user_data: rawptr,
) -> clay.Dimensions {
	context = odin_context
	text := string(text.chars[:text.length])
	c_text := strings.clone_to_cstring(text, context.temp_allocator)
	w, h: c.int
	if !sdl_ttf.GetStringSize(get_font(config.fontId, config.fontSize), c_text, 0, &w, &h) {
		log.error("Failed to measure text", sdl.GetError())
	}

	return clay.Dimensions{width = f32(w) / dpi_scaling, height = f32(h) / dpi_scaling}
}

destroy :: proc(device: ^sdl.GPUDevice) {
	destroy_quad_pipeline(device)
	destroy_text_pipeline(device)
}

/// Upload data to the GPU
prepare :: proc(
	device: ^sdl.GPUDevice,
	window: ^sdl.Window,
	cmd_buffer: ^sdl.GPUCommandBuffer,
	render_commands: ^clay.ClayArray(clay.RenderCommand),
	mouse_delta: [2]f32,
	frame_time: f32,
) {
	mouse_x, mouse_y: f32
	mouse_flags := sdl.GetMouseState(&mouse_x, &mouse_y)
	// Currently MacOS blocks main thread when resizing, this will be fixed with next SDL3 release
	window_w, window_h: c.int
	window_size := sdl.GetWindowSize(window, &window_w, &window_h)

	// Update clay internals
	clay.SetPointerState(clay.Vector2{mouse_x, mouse_y}, .LEFT in mouse_flags)
	clay.UpdateScrollContainers(true, transmute(clay.Vector2)mouse_delta, frame_time)
	clay.SetLayoutDimensions({f32(window_w), f32(window_h)})

	clear(&layers)
	clear(&tmp_quads)
	clear(&tmp_text)

	tmp_quads = make([dynamic]Quad, 0, quad_pipeline.num_instances, context.temp_allocator)
	tmp_text = make([dynamic]Text, 0, 20, context.temp_allocator)

	layer := Layer {
		scissors = make([dynamic]Scissor, 0, 10, context.temp_allocator),
	}
	scissor := Scissor{}

	// Parse render commands
	for i in 0 ..< int(render_commands.length) {
		render_command := clay.RenderCommandArray_Get(render_commands, cast(i32)i)
		bounds := render_command.boundingBox

		switch (render_command.commandType) {
		case clay.RenderCommandType.None:
		case clay.RenderCommandType.Text:
			render_data := render_command.renderData.text
			text := string(render_data.stringContents.chars[:render_data.stringContents.length])
			c_text := strings.clone_to_cstring(text, context.temp_allocator)
			sdl_text := text_pipeline.cache[render_command.id]

			if sdl_text == nil {
				// Cache a SDL text object
				sdl_text = sdl_ttf.CreateText(
					text_pipeline.engine,
					get_font(render_data.fontId, render_data.fontSize),
					c_text,
					0,
				)
				text_pipeline.cache[render_command.id] = sdl_text
			} else {
				// Update text with c_string
				_ = sdl_ttf.SetTextString(sdl_text, c_text, 0)
			}

			data := sdl_ttf.GetGPUTextDrawData(sdl_text)

			if sdl_text == nil {
				log.error("Could not create SDL text:", sdl.GetError())
			} else {
				append(
					&tmp_text,
					Text{sdl_text, {bounds.x, bounds.y}, f32_color(render_data.textColor)},
				)
				layer.text_instance_len += 1
				layer.text_vertex_len += u32(data.num_vertices)
				layer.text_index_len += u32(data.num_indices)
				scissor.text_len += 1
			}
		case clay.RenderCommandType.Image:
		case clay.RenderCommandType.ScissorStart:
			bounds := sdl.Rect {
				c.int(bounds.x * dpi_scaling),
				c.int(bounds.y * dpi_scaling),
				c.int(bounds.width * dpi_scaling),
				c.int(bounds.height * dpi_scaling),
			}
			new := new_scissor(&scissor)
			if scissor.quad_len != 0 || scissor.text_len != 0 {
				append(&layer.scissors, scissor)
			}
			scissor = new
			scissor.bounds = bounds
		case clay.RenderCommandType.ScissorEnd:
			new := new_scissor(&scissor)
			if scissor.quad_len != 0 || scissor.text_len != 0 {
				append(&layer.scissors, scissor)
			}
			scissor = new
		case clay.RenderCommandType.Rectangle:
			render_data := render_command.renderData.rectangle
			color := f32_color(render_data.backgroundColor)
			cr := render_data.cornerRadius
			quad := Quad {
				position_scale = {bounds.x, bounds.y, bounds.width, bounds.height},
				corner_radii   = {cr.bottomRight, cr.topRight, cr.bottomLeft, cr.topLeft},
				color          = color,
			}
			append(&tmp_quads, quad)
			layer.quad_len += 1
			scissor.quad_len += 1
		case clay.RenderCommandType.Border:
			render_data := render_command.renderData.border
			cr := render_data.cornerRadius
			//TODO dedicated border pipeline
			quad := Quad {
				position_scale = {bounds.x, bounds.y, bounds.width, bounds.height},
				corner_radii   = {cr.bottomRight, cr.topRight, cr.bottomLeft, cr.topLeft},
				color          = f32_color(clay.Color{0.0, 0.0, 0.0, 0.0}),
				border_color   = f32_color(render_data.color),
				// We only support one border width at the moment
				border_width   = f32(render_data.width.top),
			}
			// Technically these should be drawn on top of everything else including children, but
			// for our use case we can just chuck these in with the quad pipeline
			append(&tmp_quads, quad)
			layer.quad_len += 1
			scissor.quad_len += 1
		case clay.RenderCommandType.Custom:
		}
	}

	//TODO start new layers with z-index changes
	append(&layer.scissors, scissor)
	append(&layers, layer)

	// Upload primitives to GPU
	copy_pass := sdl.BeginGPUCopyPass(cmd_buffer)
	upload_quads(device, copy_pass)
	upload_text(device, copy_pass)
	sdl.EndGPUCopyPass(copy_pass)
}

/// Render primitives
draw :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, cmd_buffer: ^sdl.GPUCommandBuffer) {
	swapchain_texture: ^sdl.GPUTexture
	w, h: u32
	if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buffer, window, &swapchain_texture, &w, &h) {
		log.error("Failed to acquire swapchain texture:", sdl.GetError())
		os.exit(1)
	}

	if swapchain_texture == nil {
		log.error("Failed to acquire swapchain texture:", sdl.GetError())
		os.exit(1)
	}

	for &layer, index in layers {
		draw_quads(
			device,
			window,
			cmd_buffer,
			swapchain_texture,
			w,
			h,
			&layer,
			index == 0 ? sdl.GPULoadOp.CLEAR : sdl.GPULoadOp.LOAD,
		)
		draw_text(device, window, cmd_buffer, swapchain_texture, w, h, &layer)
		//TODO draw other primitives in layer
	}
}

ortho_rh :: proc(
	left: f32,
	right: f32,
	bottom: f32,
	top: f32,
	near: f32,
	far: f32,
) -> matrix[4, 4]f32 {
	return matrix[4, 4]f32{
		2.0 / (right - left), 0.0, 0.0, -(right + left) / (right - left), 
		0.0, 2.0 / (top - bottom), 0.0, -(top + bottom) / (top - bottom), 
		0.0, 0.0, -2.0 / (far - near), -(far + near) / (far - near), 
		0.0, 0.0, 0.0, 1.0, 
	}
}

f32_color :: proc(color: clay.Color) -> [4]f32 {
	return [4]f32{color.x / 255.0, color.y / 255.0, color.z / 255.0, color.w / 255.0}
}

Globals :: struct {
	projection: matrix[4, 4]f32,
	scale:      f32,
}

push_globals :: proc(cmd_buffer: ^sdl.GPUCommandBuffer, w: f32, h: f32) {
	globals := Globals {
		ortho_rh(left = 0.0, top = 0.0, right = f32(w), bottom = f32(h), near = -1.0, far = 1.0),
		dpi_scaling,
	}

	sdl.PushGPUVertexUniformData(cmd_buffer, 0, &globals, size_of(Globals))
}

new_scissor :: proc(old: ^Scissor) -> Scissor {
	return Scissor {
		quad_start = old.quad_start + old.quad_len,
		text_start = old.text_start + old.text_len,
	}
}
