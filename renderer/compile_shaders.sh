#!/bin/sh
if ! command -v glslangValidator 2>&1 > /dev/null
then
    echo "glslangValidator not found"
    exit 1
fi

if ! command -v spirv-cross 2>&1 > /dev/null
then
    echo "spirv-cross not found"
    exit 1
fi

# Convert GLSL to SPIRV
echo "Converting GLSL shaders to SPIRV..."
mkdir -p renderer/res/shaders/compiled
cd renderer/res/shaders/raw || exit
glslangValidator -V quad.vert -o ../compiled/quad.vert.spv
glslangValidator -V quad.frag -o ../compiled/quad.frag.spv
glslangValidator -V text.vert -o ../compiled/text.vert.spv
glslangValidator -V text.frag -o ../compiled/text.frag.spv
glslangValidator -V scene.vert -o ../compiled/scene.vert.spv
glslangValidator -V scene.frag -o ../compiled/scene.frag.spv

# Convert SPIRV to MSL
echo "Done converting GLSL to SPIRV. Converting SPIRV to MSL..."
cd ../compiled || exit
spirv-cross --msl quad.vert.spv --output quad.vert.metal
spirv-cross --msl quad.frag.spv --output quad.frag.metal
spirv-cross --msl text.vert.spv --output text.vert.metal
spirv-cross --msl text.frag.spv --output text.frag.metal
spirv-cross --msl scene.vert.spv --output scene.vert.metal
spirv-cross --msl scene.frag.spv --output scene.frag.metal

echo "Done processing shaders."