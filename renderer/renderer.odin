package renderer

import clay "../clay"
import "base:runtime"
import "core:c"
import "core:log"
import "core:os"
import "core:strings"
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

// I need to make it so that I can
// a) Add primitives directly to a layer
// b) Create small nested clay-layouts that can be batched with other shit
// Some colletion of items, where its just primtiives, but collections of primitives? And each collection has a type,
// either raw or clay? Or something

// Prepare - upload to GPU
// With clay commands, this requires converting to my custom primitive types
// With raw commands, this would require no conversion
// Need to go from UI declaration -> processing render cmds

// I want to process & upload in the same loop, don't want to add an additional pass where I transform
// clay cmds -> my primitives

// 1) I need to be able to process all clay cmds & all raw primitive cmds in a single iteration
// 2) I need to be able to define (at a layout level) which primitives can be rendered in the same batch
//
// Some kind of queue? Each UI element adds to a temp queue that is reset every frame
// Queue is like
//  [ chunk of primitives ] [ chunk of clay primitives ] [ new layer indicator ] [ chunk ]
Rectangle :: struct {
	x: f32,
	y: f32,
	w: f32,
	h: f32,
}

Layer :: struct {
	bounds:              Rectangle,
	quad_instance_start: u32,
	quad_len:            u32,
	text_instance_start: u32,
	text_instance_len:   u32,
	text_vertex_start:   u32,
	text_vertex_len:     u32,
	text_index_start:    u32,
	text_index_len:      u32,
	curr_scissor_index:  u32,
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

@(private = "file")
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

/// Sets up renderer to begin upload to the GPU. Returns starting `Layer` to begin processing primitives for
begin_prepare :: proc() -> Layer {
	// Prepare to upload to GPU
	clear(&layers)
	clear(&tmp_quads)
	clear(&tmp_text)

	tmp_quads = make([dynamic]Quad, 0, quad_pipeline.num_instances, context.temp_allocator)
	tmp_text = make([dynamic]Text, 0, 20, context.temp_allocator)

	layer := Layer {
		scissors = make([dynamic]Scissor, 0, 10, context.temp_allocator),
	}

	return layer
}

/// Creates a new layer, appending the old one to `layers`
new_layer :: proc(layer: ^Layer, bounds: Rectangle) -> Layer {
	append(&layers, layer^)
	layer := Layer {
		bounds   = bounds,
		scissors = make([dynamic]Scissor, 0, 10, context.temp_allocator),
	}

	return layer
}

end_prepare :: proc(device: ^sdl.GPUDevice, cmd_buffer: ^sdl.GPUCommandBuffer, layer: ^Layer) {
	// Commit last layer worked on
	append(&layers, layer^)

	// Upload primitives to GPU
	copy_pass := sdl.BeginGPUCopyPass(cmd_buffer)
	upload_quads(device, copy_pass)
	upload_text(device, copy_pass)
	sdl.EndGPUCopyPass(copy_pass)
}

// ===== Built-in primitive processing =====
//prepare_batch :: proc(
//	device: ^sdl.GPUDevice,
//	window: ^sdl.Window,
//	cmd_buffer: ^sdl.GPUCommandBuffer,
//	layer: ^Layer,
//	primitives: ^[]Primitive,
//) {
//	scissor := Scissor{}
//
//
//}

// ====== Clay-specific processing ======
ClayBatch :: struct {
	bounds: Rectangle,
	cmds:   clay.ClayArray(clay.RenderCommand),
}

/// Upload data to the GPU
prepare_clay_batch :: proc(
	device: ^sdl.GPUDevice,
	window: ^sdl.Window,
	cmd_buffer: ^sdl.GPUCommandBuffer,
	layer: ^Layer,
	mouse_pos: [2]f32,
	mouse_flags: sdl.MouseButtonFlags,
	mouse_wheel_delta: [2]f32,
	frame_time: f32,
	batch: ^ClayBatch,
) {
	// Update clay internals
	clay.SetPointerState(
		clay.Vector2{mouse_pos.x - layer.bounds.x, mouse_pos.y - layer.bounds.y},
		.LEFT in mouse_flags,
	)
	clay.UpdateScrollContainers(true, transmute(clay.Vector2)mouse_wheel_delta, frame_time)

	scissor := Scissor{}

	// Parse render commands
	for i in 0 ..< int(batch.cmds.length) {
		render_command := clay.RenderCommandArray_Get(&batch.cmds, cast(i32)i)
		// Translate bounding box of the primitive by the layer position
		bounds := Rectangle {
			x = render_command.boundingBox.x + layer.bounds.x,
			y = render_command.boundingBox.y + layer.bounds.y,
			w = render_command.boundingBox.width,
			h = render_command.boundingBox.height,
		}

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
				c.int(bounds.w * dpi_scaling),
				c.int(bounds.h * dpi_scaling),
			}
			if scissor.quad_len != 0 || scissor.text_len != 0 {
				new := new_scissor(&scissor)
				append(&layer.scissors, scissor)
				scissor = new
			}

			scissor.bounds = bounds
		case clay.RenderCommandType.ScissorEnd:
			if scissor.quad_len != 0 || scissor.text_len != 0 {
				new := new_scissor(&scissor)
				append(&layer.scissors, scissor)
				scissor = new
			}
		case clay.RenderCommandType.Rectangle:
			render_data := render_command.renderData.rectangle
			color := f32_color(render_data.backgroundColor)
			cr := render_data.cornerRadius
			quad := Quad {
				position_scale = {bounds.x, bounds.y, bounds.w, bounds.h},
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
				position_scale = {bounds.x, bounds.y, bounds.w, bounds.h},
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

	if scissor.quad_len != 0 || scissor.text_len != 0 {
		append(&layer.scissors, scissor)
	}
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
