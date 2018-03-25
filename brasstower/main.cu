//#include "kernel.cuh"
#include <GL/glew.h>
#include <GLFW/glfw3.h>
#include <glm/glm.hpp>
#include <glm/ext.hpp>

#include "cuda/helper.cuh"
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <cuda_gl_interop.h>

#include <ctime>
#include <chrono>

#include "ext/helper_math.h"
#include "opengl/shader.h"
#include "mesh.h"
#include "scene.h"

#include "particlerenderer.cuh"
#include "particlesolver.cuh"

GLFWwindow * window;
ParticleRenderer * renderer;
ParticleSolver * solver;

void updateControl()
{
	// mouse control
	{
		static glm::dvec2 prevMousePos = [&]()
		{
			glm::dvec2 mousePos;
			glfwGetCursorPos(window, &mousePos.y, &mousePos.x);
			return mousePos;
		}();

		glm::vec2 rotation(0.0f);
		glm::dvec2 mousePos;
		glfwGetCursorPos(window, &mousePos.y, &mousePos.x);

		//if (glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_LEFT) == GLFW_PRESS)

		if (glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS)
			rotation += (mousePos - prevMousePos);

		glm::dvec2 diff = (mousePos - prevMousePos); 
		prevMousePos = mousePos;
		renderer->camera.rotate(rotation * glm::vec2(0.005f, 0.005f));
	}

	// key control
	{
		glm::vec3 control(0.0f);
		if (glfwGetKey(window, GLFW_KEY_W) == GLFW_PRESS)
			control += glm::vec3(0.f, 0.f, 1.f);
		if (glfwGetKey(window, GLFW_KEY_S) == GLFW_PRESS)
			control -= glm::vec3(0.f, 0.f, 1.f);
		if (glfwGetKey(window, GLFW_KEY_A) == GLFW_PRESS)
			control += glm::vec3(1.f, 0.f, 0.f);
		if (glfwGetKey(window, GLFW_KEY_D) == GLFW_PRESS)
			control -= glm::vec3(1.f, 0.f, 0.f);
		if (glfwGetKey(window, GLFW_KEY_SPACE) == GLFW_PRESS)
			control += glm::vec3(0.f, 1.f, 0.f);
		if (glfwGetKey(window, GLFW_KEY_LEFT_CONTROL) == GLFW_PRESS)
			control -= glm::vec3(0.f, 1.f, 0.f);
		float length = glm::length(control);
		control = length > 0 ? control / length : control;
		renderer->camera.shift(control * 0.1f);
	}
}

std::vector<glm::vec3> CreateBoxParticles(const glm::ivec3 & dimension, const glm::vec3 & startPosition, const glm::vec3 & stepSize)
{
	std::vector<glm::vec3> positions;
	for (int i = 0; i < dimension.x; i++)
		for (int j = 0; j < dimension.y; j++)
			for (int k = 0; k < dimension.z; k++)
			{
				positions.push_back(startPosition + stepSize * glm::vec3(i, j, k));
			}
	return positions;
}

std::shared_ptr<Scene> initSimpleScene()
{
	std::shared_ptr<Scene> scene = std::make_shared<Scene>();
	scene->planes.push_back(Plane(glm::vec3(0), glm::vec3(0, 1, 0)));
	scene->planes.push_back(Plane(glm::vec3(0, 0, -1.9), glm::normalize(glm::vec3(0, 0, 1))));
	scene->planes.push_back(Plane(glm::vec3(0, 0, 1.9), glm::normalize(glm::vec3(0, 0, -1))));
	scene->planes.push_back(Plane(glm::vec3(-2.8, 0, 0), glm::normalize(glm::vec3(1, 0, 0))));
	scene->planes.push_back(Plane(glm::vec3(2.8, 0, 0), glm::normalize(glm::vec3(-1, 0, 0))));
	scene->numParticles = 0;
	scene->numMaxParticles = 50000;
	scene->radius = 0.05f;
	return scene;
}

__global__ void mapPositions(float4 * ssboDptr, float3 * position, const int numParticles)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i >= numParticles) { return; }
	ssboDptr[i] = make_float4(position[i].x, position[i].y, position[i].z, 0.0f);
}

int main()
{
	cudaGLSetGLDevice(0);
	window = InitGL(1280, 720);

	std::shared_ptr<Scene> scene = initSimpleScene();
	renderer = new ParticleRenderer(glm::uvec2(1280, 720), scene);
	solver = new ParticleSolver(scene);
	solver->addRigidBody(CreateBoxParticles(glm::ivec3(2, 1, 2), glm::vec3(0 - scene->radius, scene->radius, 0 - scene->radius), glm::vec3(scene->radius * 2.0f)), 1.0f);
	solver->addParticles(glm::ivec3(1, 1, 1), glm::vec3(0, 1.5, 0), glm::vec3(scene->radius * 2.0f), 1.0f);
	//solver->addParticles(glm::ivec3(40, 50, 20), glm::vec3(0 - scene->radius, scene->radius, 0 - scene->radius), glm::vec3(scene->radius * 2.0f), 1.0f);

	// fps counter
	std::chrono::high_resolution_clock::time_point lastUpdateTime = std::chrono::high_resolution_clock::now();
	int numFrame = 0;

	do
	{
		updateControl();

		// solver update
		solver->update(2, 1.0f / 60.0f);

		// renderer update
		float4 *dptr = renderer->mapSsbo();
		int numBlocks, numThreads;
		GetNumBlocksNumThreads(&numBlocks, &numThreads, scene->numParticles);
		mapPositions<<<numBlocks, numThreads>>>(dptr, solver->devPositions, scene->numParticles);
		renderer->unmapSsbo();
		renderer->update();

		// Swap buffers
		glfwSwapBuffers(window);
		glfwPollEvents();

		// update fps counter
		std::chrono::high_resolution_clock::time_point currentTime = std::chrono::high_resolution_clock::now();
		long long elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(currentTime - lastUpdateTime).count();
		if (elapsedMs >= 100)
		{
			glfwSetWindowTitle(window, std::to_string((float)elapsedMs / (float)numFrame).c_str());
			numFrame = 0;
			lastUpdateTime = currentTime;
		}

		numFrame++;
	} // Check if the ESC key was pressed or the window was closed
	while (glfwGetKey(window, GLFW_KEY_ESCAPE) != GLFW_PRESS && glfwWindowShouldClose(window) == 0);

	delete renderer;
	delete solver;
	return 0;
}