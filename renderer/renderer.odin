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
INITIAL_LAYER_SIZE :: 5
INITIAL_SCISSOR_SIZE :: 10

Global :: struct {
	dpi_scaling:      f32,
	curr_layer_index: uint,
	layers:           [dynamic]Layer,
	max_layers:       int,
	scissors:         [dynamic]Scissor,
	max_scissors:     int,
	tmp_text:         [dynamic]Text,
	max_tmp_text:     int,
	tmp_quads:        [dynamic]Quad,
	max_tmp_quads:    int,
	clay_mem:         [^]u8,
	clay_z_index:     i16,
	odin_context:     runtime.Context,
	quad_pipeline:    QuadPipeline,
	text_pipeline:    TextPipeline,
}

// TODO every x frames nuke max values in case of edge cases where max gets set very high
// Called at the end of every frame
resize_global :: proc() {
	using global

	if len(layers) > max_layers do max_layers = len(layers)
	shrink(&layers, max_layers)
	if len(scissors) > max_scissors do max_scissors = len(scissors)
	shrink(&scissors, max_scissors)
	if len(tmp_text) > max_tmp_text do max_tmp_text = len(tmp_text)
	shrink(&tmp_text, max_tmp_text)
	if len(tmp_quads) > max_tmp_quads do max_tmp_quads = len(tmp_quads)
	shrink(&tmp_quads, max_tmp_quads)
}

destroy :: proc(device: ^sdl.GPUDevice) {
	using global
	delete(layers)
	delete(scissors)
	delete(tmp_text)
	delete(tmp_quads)
	free(clay_mem)
	destroy_quad_pipeline(device)
	destroy_text_pipeline(device)
}

clear_global :: proc() {
	using global

	curr_layer_index = 0
	clay_z_index = 0
	clear(&layers)
	clear(&scissors)
	clear(&tmp_text)
	clear(&tmp_quads)
}

global: Global

Rectangle :: struct {
	x: f32,
	y: f32,
	w: f32,
	h: f32,
}

Layer :: struct {
	bounds:              Rectangle,
	quad_instance_start: u32,
	quad_instance_len:   u32,
	text_instance_start: u32,
	text_instance_len:   u32,
	text_vertex_start:   u32,
	text_vertex_len:     u32,
	text_index_start:    u32,
	text_index_len:      u32,
	scissor_start:       u32,
	scissor_len:         u32,
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
	min_memory_size: c.size_t = cast(c.size_t)clay.MinMemorySize()

	global = Global {
		layers        = make([dynamic]Layer, 0, INITIAL_LAYER_SIZE),
		scissors      = make([dynamic]Scissor, 0, INITIAL_SCISSOR_SIZE),
		tmp_quads     = make([dynamic]Quad, 0, BUFFER_INIT_SIZE),
		tmp_text      = make([dynamic]Text, 0, BUFFER_INIT_SIZE),
		odin_context  = ctx,
		dpi_scaling   = sdl.GetWindowDisplayScale(window),
		clay_mem      = make([^]u8, min_memory_size),
		quad_pipeline = create_quad_pipeline(device, window),
		text_pipeline = create_text_pipeline(device, window),
	}
	log.debug("Window DPI scaling:", global.dpi_scaling)
	arena := clay.CreateArenaWithCapacityAndMemory(min_memory_size, global.clay_mem)

	clay.Initialize(arena, {window_width, window_height}, {handler = clay_error_handler})
	clay.SetMeasureTextFunction(measure_text, nil)
}

@(private = "file")
clay_error_handler :: proc "c" (errorData: clay.ErrorData) {
	context = global.odin_context
	log.error("Clay error:", errorData.errorType, errorData.errorText)
}

@(private = "file")
measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	user_data: rawptr,
) -> clay.Dimensions {
	using global
	context = odin_context
	text := string(text.chars[:text.length])
	c_text := strings.clone_to_cstring(text, context.temp_allocator)
	w, h: c.int
	if !sdl_ttf.GetStringSize(get_font(config.fontId, config.fontSize), c_text, 0, &w, &h) {
		log.error("Failed to measure text", sdl.GetError())
	}

	return clay.Dimensions{width = f32(w) / dpi_scaling, height = f32(h) / dpi_scaling}
}

/// Sets up renderer to begin upload to the GPU. Returns starting `Layer` to begin processing primitives for
begin_prepare :: proc(bounds: Rectangle) -> ^Layer {
	using global
	// Cleanup
	clear_global()

	// Begin new layer
	// Start a new scissor
	scissor := Scissor {
		bounds = sdl.Rect {
			x = i32(bounds.x * dpi_scaling),
			y = i32(bounds.y * dpi_scaling),
			w = i32(bounds.w * dpi_scaling),
			h = i32(bounds.h * dpi_scaling),
		},
	}
	append(&scissors, scissor)

	layer := Layer {
		bounds      = bounds,
		scissor_len = 1,
	}
	append(&layers, layer)
	return &layers[curr_layer_index]
}

/// Creates a new layer
new_layer :: proc(prev_layer: ^Layer, bounds: Rectangle) -> ^Layer {
	using global
	layer := Layer {
		bounds              = bounds,
		quad_instance_start = prev_layer.quad_instance_start + prev_layer.quad_instance_len,
		text_instance_start = prev_layer.text_instance_start + prev_layer.text_instance_len,
		text_vertex_start   = prev_layer.text_vertex_start + prev_layer.text_vertex_len,
		text_index_start    = prev_layer.text_index_start + prev_layer.text_index_len,
		scissor_start       = prev_layer.scissor_start + prev_layer.scissor_len,
		scissor_len         = 1,
	}
	append(&layers, layer)
	curr_layer_index += 1
	log.debug("Added new layer; curr index", curr_layer_index)

	scissor := Scissor {
		bounds = sdl.Rect {
			x = i32(bounds.x * dpi_scaling),
			y = i32(bounds.y * dpi_scaling),
			w = i32(bounds.w * dpi_scaling),
			h = i32(bounds.h * dpi_scaling),
		},
	}
	append(&scissors, scissor)
	return &layers[curr_layer_index]
}

end_prepare :: proc(device: ^sdl.GPUDevice, cmd_buffer: ^sdl.GPUCommandBuffer) {
	// Upload primitives to GPU
	copy_pass := sdl.BeginGPUCopyPass(cmd_buffer)
	upload_quads(device, copy_pass)
	upload_text(device, copy_pass)
	sdl.EndGPUCopyPass(copy_pass)

	// Resize my dynamic arrays
	resize_global()
}

// ===== Built-in primitive processing =====
// TODO scissoring support if I need it for primitives
prepare_quad :: proc(layer: ^Layer, quad: Quad) {
	using global

	append(&tmp_quads, quad)
	layer.quad_instance_len += 1
	scissors[layer.scissor_start + layer.scissor_len - 1].quad_len += 1
}

// TODO need to make sure no overlap with clay render command IDs
prepare_text :: proc(layer: ^Layer, text: Text) {
	using global

	data := sdl_ttf.GetGPUTextDrawData(text.ref)
	if data == nil {
		log.error("Failed to find GPUTextDrawData for sdl_text")
	}

	append(&tmp_text, text)
	layer.text_instance_len += 1
	layer.text_vertex_len += u32(data.num_vertices)
	layer.text_index_len += u32(data.num_indices)
	scissors[layer.scissor_start + layer.scissor_len - 1].text_len += 1
}

// ====== Clay-specific processing ======
ClayBatch :: struct {
	bounds: Rectangle,
	cmds:   clay.ClayArray(clay.RenderCommand),
}

/// Upload data to the GPU
prepare_clay_batch :: proc(
	base_layer: ^Layer,
	mouse_pos: [2]f32,
	mouse_flags: sdl.MouseButtonFlags,
	mouse_wheel_delta: [2]f32,
	frame_time: f32,
	batch: ^ClayBatch,
) {
	using global

	// Update clay internals
	clay.SetPointerState(
		clay.Vector2{mouse_pos.x - base_layer.bounds.x, mouse_pos.y - base_layer.bounds.y},
		.LEFT in mouse_flags,
	)
	clay.UpdateScrollContainers(true, transmute(clay.Vector2)mouse_wheel_delta, frame_time)

	layer := base_layer

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

		if render_command.zIndex > clay_z_index {
			log.debug(
				"Higher zIndex found, creating new layer & setting z_index to",
				render_command.zIndex,
			)
			layer = new_layer(layer, bounds)
			// Update bounds to new layer offset
			bounds.x = render_command.boundingBox.x + layer.bounds.x
			bounds.y = render_command.boundingBox.y + layer.bounds.y
			clay_z_index = render_command.zIndex
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
			if data == nil {
				log.error("Failed to find GPUTextDrawData for sdl_text:", c_text)
			}

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
				scissors[layer.scissor_start + layer.scissor_len - 1].text_len += 1
			}
		case clay.RenderCommandType.Image:
		case clay.RenderCommandType.ScissorStart:
			if bounds.w == 0 || bounds.h == 0 {
				continue
			}

			curr_scissor := &scissors[layer.scissor_start + layer.scissor_len - 1]

			if curr_scissor.quad_len != 0 || curr_scissor.text_len != 0 {
				// Scissor has some content, need to make a new scissor
				new := Scissor {
					quad_start = curr_scissor.quad_start + curr_scissor.quad_len,
					text_start = curr_scissor.text_start + curr_scissor.text_len,
					bounds     = sdl.Rect {
						c.int(bounds.x * dpi_scaling),
						c.int(bounds.y * dpi_scaling),
						c.int(bounds.w * dpi_scaling),
						c.int(bounds.h * dpi_scaling),
					},
				}
				append(&scissors, new)
				layer.scissor_len += 1
			} else {
				curr_scissor.bounds = sdl.Rect {
					c.int(bounds.x * dpi_scaling),
					c.int(bounds.y * dpi_scaling),
					c.int(bounds.w * dpi_scaling),
					c.int(bounds.h * dpi_scaling),
				}
			}
		case clay.RenderCommandType.ScissorEnd:
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

			layer.quad_instance_len += 1
			scissors[layer.scissor_start + layer.scissor_len - 1].quad_len += 1
		case clay.RenderCommandType.Border:
			render_data := render_command.renderData.border
			cr := render_data.cornerRadius
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
			layer.quad_instance_len += 1
			scissors[layer.scissor_start + layer.scissor_len - 1].quad_len += 1
		case clay.RenderCommandType.Custom:
		}
	}
}

/// Render primitives
draw :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, cmd_buffer: ^sdl.GPUCommandBuffer) {
	using global
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
		log.debug("Drawing layer", index)
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
		//TODO draw other primitives in layer once I add support for them :)
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
		global.dpi_scaling,
	}

	sdl.PushGPUVertexUniformData(cmd_buffer, 0, &globals, size_of(Globals))
}
