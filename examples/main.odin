package main

import "../renderer"
import "core:c"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import clay "library:clay"
import sdl "vendor:sdl3"

WINDOW_WIDTH :: 1024
WINDOW_HEIGHT :: 728
WINDOW_FLAGS :: sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY}

window: ^sdl.Window
device: ^sdl.GPUDevice
debug_enabled := false

body_text := clay.TextElementConfig {
	fontId             = renderer.JETBRAINS_MONO_REGULAR,
	fontSize           = 44,
	textColor          =  { 1.0, 1.0, 1.0, 1.0 },
}

main :: proc() {
	defer destroy()

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

	window = sdl.CreateWindow("System Controller", WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_FLAGS)

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

		if update(cmd_buffer, frame_time - last_frame_time) {
			log.debug("User command to quit")
			break program
		}

		draw(cmd_buffer)

		last_frame_time = frame_time
	}
}

destroy :: proc() {
	renderer.destroy(device)
	sdl.ReleaseWindowFromGPUDevice(device, window)
	sdl.DestroyWindow(window)
	sdl.DestroyGPUDevice(device)
}

update :: proc(cmd_buffer: ^sdl.GPUCommandBuffer, delta_time: u64) -> bool {
	frame_time := f32(delta_time) / 1000.0
	input := input()

	render_cmds: clay.ClayArray(clay.RenderCommand) = layout()

	renderer.prepare(device, window, cmd_buffer, &render_cmds, input.mouse_delta, frame_time)

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

layout :: proc() -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()

	if clay.UI()(
	{
		id = clay.ID("OuterContainer"),
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
			childAlignment = {x = .Center, y = .Center},
			childGap = 16,
		},
		backgroundColor = {0.2, 0.2, 0.2, 1.0},
	},
	) {
		clay.Text("3D SCENE", &body_text)
	}

	return clay.EndLayout()
}

