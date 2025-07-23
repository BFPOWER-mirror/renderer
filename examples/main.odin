package main

import clay "../clay"
import "../renderer"
import "core:c"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import sdl "vendor:sdl3"

WINDOW_WIDTH :: 1024
WINDOW_HEIGHT :: 728
WINDOW_FLAGS :: sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY}

window: ^sdl.Window
device: ^sdl.GPUDevice
debug_enabled := false

body_text := clay.TextElementConfig {
	fontId    = renderer.JETBRAINS_MONO_REGULAR,
	fontSize  = 44,
	textColor = {0.0, 0.0, 0.0, 255.0},
}

main :: proc() {
	when ODIN_DEBUG == true {
		context.logger = log.create_console_logger(lowest = .Debug)

		//----- Tracking allocator ----------------------------------
		// Temp
		track_temp: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track_temp, context.temp_allocator)
		context.temp_allocator = mem.tracking_allocator(&track_temp)
		// Default
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		// Log a warning about any memory that was not freed by the end of the program.
		// This could be fine for some global state or it could be a memory leak.
		defer {
			// Temp allocator
			if len(track_temp.allocation_map) > 0 {
				fmt.eprintf(
					"=== %v allocations not freed - temp allocator: ===\n",
					len(track_temp.allocation_map),
				)
				for _, entry in track_temp.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track_temp.bad_free_array) > 0 {
				fmt.eprintf(
					"=== %v incorrect frees - temp allocator: ===\n",
					len(track_temp.bad_free_array),
				)
				for entry in track_temp.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track_temp)
			// Default allocator
			if len(track.allocation_map) > 0 {
				fmt.eprintf(
					"=== %v allocations not freed - main allocator: ===\n",
					len(track.allocation_map),
				)
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf(
					"=== %v incorrect frees - main allocator: ===\n",
					len(track.bad_free_array),
				)
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	if !sdl.Init(sdl.InitFlags{.VIDEO}) {
		log.error("Failed to initialize SDL:", sdl.GetError())
	}

	window = sdl.CreateWindow("Test", WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_FLAGS)

	if window == nil {
		log.error("Failed to create window:", sdl.GetError())
		os.exit(1)
	}

	device = sdl.CreateGPUDevice(renderer.SHADER_TYPE, true, nil)
	if device == nil {
		log.error("Failed to create GPU device:", sdl.GetError())
		os.exit(1)
	}
	driver := sdl.GetGPUDeviceDriver(device)
	log.info("Created GPU device:", driver)

	if !sdl.ClaimWindowForGPUDevice(device, window) {
		log.error("Failed to claim GPU device for window:", sdl.GetError())
		os.exit(1)
	}

	renderer.init(device, window, WINDOW_WIDTH, WINDOW_HEIGHT, context)

	// debug
	FPS_REFRESH_INTERVAL :: 1000.0 // 1 second
	fps_time := sdl.GetTicks()
	frame_count: int
	fps: f32

	last_frame_time := sdl.GetTicks()

	program: for {
		defer free_all(context.temp_allocator)

		// Update debug FPS
		frame_time := sdl.GetTicks()
		when ODIN_DEBUG == true {
			frame_count += 1
			if frame_time - fps_time >= FPS_REFRESH_INTERVAL {
				new_fps := f32(frame_count)
				if new_fps != fps {
					log.info("FPS:", new_fps)
				}
				fps = new_fps
				frame_count = 0
				fps_time = frame_time
			}
		}

		cmd_buffer := sdl.AcquireGPUCommandBuffer(device)
		if cmd_buffer == nil {
			log.error("Failed to acquire command buffer")
			os.exit(1)
		}

		should_quit := update(cmd_buffer, frame_time - last_frame_time)

		if should_quit {
			log.debug("User command to quit")
			break program
		}

		draw(cmd_buffer)

		last_frame_time = frame_time
	}

	destroy()
}

destroy :: proc() {
	free_all(context.temp_allocator)
	renderer.destroy(device)
	sdl.ReleaseWindowFromGPUDevice(device, window)
	sdl.DestroyWindow(window)
	sdl.DestroyGPUDevice(device)
}

update :: proc(cmd_buffer: ^sdl.GPUCommandBuffer, delta_time: u64) -> bool {
	frame_time := f32(delta_time) / 1000.0
	input := input()
	mouse_x, mouse_y: f32
	mouse_flags := sdl.GetMouseState(&mouse_x, &mouse_y)
	width, height: c.int
	sdl.GetWindowSize(window, &width, &height)
	window_bounds := renderer.Rectangle {
		x = 0.0,
		y = 0.0,
		w = f32(width),
		h = f32(height),
	}

	layer := renderer.begin_prepare(window_bounds)
	// ===== Begin processing primitives for GPU upload =====
	// Everything after begin_prepare() is uploaded in-order. We pass the layer down
	// until we need a new one, after which we call new_layer()

	// Process primitives on this layer
	layout(layer)

	// Process clay-specific primitives
	clay_layer_bounds := renderer.Rectangle {
		x = f32(width) / 2.0,
		y = 0.0,
		w = f32(width) / 2.0,
		h = f32(height),
	}
	// Create a new layer, because these two scenes cannot be renderer in the same batch due to overlap
	layer = renderer.new_layer(layer, clay_layer_bounds)
	clay_batch := clay_layout(clay_layer_bounds)
	renderer.prepare_clay_batch(
		layer,
		{mouse_x, mouse_y},
		mouse_flags,
		input.mouse_delta,
		frame_time,
		&clay_batch,
	)

	// This uploads the primitive data to the GPU
	renderer.end_prepare(device, cmd_buffer)

	return input.should_quit
}

Input :: struct {
	mouse_delta: [2]f32,
	should_quit: bool,
}

input :: proc() -> Input {
	result := Input{}

	event: sdl.Event
	for sdl.PollEvent(&event) == true {
		#partial switch event.type {
		case .KEY_DOWN:
			switch event.key.key {
			case sdl.K_ESCAPE:
				result.should_quit = true
			case sdl.K_D:
				if .LSHIFT in event.key.mod {
					debug_enabled = !debug_enabled
					clay.SetDebugModeEnabled(debug_enabled)
				}
			}
		case .QUIT:
			result.should_quit = true
		case .MOUSE_WHEEL:
			result.mouse_delta[0] = event.wheel.x
			result.mouse_delta[1] = event.wheel.y
		}
	}

	return result
}

draw :: proc(cmd_buffer: ^sdl.GPUCommandBuffer) {
	renderer.draw(device, window, cmd_buffer)
	submit_ok := sdl.SubmitGPUCommandBuffer(cmd_buffer)
	if !submit_ok {
		log.debug("Failed to submit command buffer:", sdl.GetError())
	}
}

clay_layout :: proc(bounds: renderer.Rectangle) -> renderer.ClayBatch {
	clay.SetLayoutDimensions(clay.Dimensions{bounds.w, bounds.h})
	clay.BeginLayout()

	if clay.UI()(
	{
		id = clay.ID("OuterContainer"),
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
			childAlignment = {x = .Center, y = .Center},
			childGap = 32,
		},
		backgroundColor = {200.0, 200.0, 200.0, 100.0},
	},
	) {
		if clay.UI()(
		{
			id = clay.ID("RoundedRect"),
			backgroundColor = {255.0, 100.0, 100.0, 255.0},
			cornerRadius = clay.CornerRadius {
				topLeft = 10,
				topRight = 20,
				bottomLeft = 40,
				bottomRight = 0,
			},
			border = clay.BorderElementConfig {
				color = {0.0, 0.0, 0.0, 255.0},
				width = clay.BorderAll(5),
			},
			layout = {sizing = {clay.SizingFixed(240), clay.SizingFixed(80)}},
		},
		) {
		}

		if clay.UI()(
		{
			id = clay.ID("RoundedRect2"),
			backgroundColor = {255.0, 100.0, 100.0, 255.0},
			cornerRadius = clay.CornerRadius {
				topLeft = 10,
				topRight = 20,
				bottomLeft = 40,
				bottomRight = 0,
			},
			border = clay.BorderElementConfig {
				color = {0.0, 0.0, 0.0, 255.0},
				width = clay.BorderAll(5),
			},
			layout = {sizing = {clay.SizingFixed(240), clay.SizingFixed(80)}},
		},
		) {
		}

		clay.Text("Test Text", &body_text)
	}

	return renderer.ClayBatch{bounds, clay.EndLayout()}
}

layout :: proc(layer: ^renderer.Layer) {
	bounds := layer.bounds

	test_quad := renderer.quad(
		pos = {bounds.x + 200, bounds.y + 200},
		size = {bounds.w / 2.0, bounds.h / 2.0},
		color = {0.2, 0.2, 0.8, 1},
		corner_radii = {5, 10, 0, 20},
		border_color = {0, 0, 0, 1},
		border_width = 10,
	)
	renderer.prepare_quad(layer, test_quad)

	text_ok, text := renderer.text(0, "Raw Text", {bounds.x + 80, bounds.y + 80})
	if text_ok {
		renderer.prepare_text(layer, text)
	}
}
