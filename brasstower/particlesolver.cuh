#include <exception>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <cuda_gl_interop.h>
#include <conio.h>

#include "cuda/helper.cuh"
#include "cuda/cudaglm.cuh"
#include "scene.h"

void GetNumBlocksNumThreads(int * numBlocks, int * numThreads, int k)
{
	*numThreads = 512;
	*numBlocks = static_cast<int>(ceil((float)k / (float)(*numThreads)));
}

void print(float3 * dev, int size)
{
	float3 * tmp = (float3 *)malloc(sizeof(float3) * size);
	cudaMemcpy(tmp, dev, sizeof(float3) * size, cudaMemcpyDeviceToHost);
	for (int i = 0; i < size; i++)
	{
		std::cout << "(" << tmp[i].x << " " << tmp[i].y << " " << tmp[i].z << ")";
		if (i != size - 1)
			std::cout << ",";
	}
	std::cout << std::endl;
	free(tmp);
}


void print(float * dev, int size)
{
	float * tmp = (float *)malloc(sizeof(float) * size);
	cudaMemcpy(tmp, dev, sizeof(float) * size, cudaMemcpyDeviceToHost);
	for (int i = 0; i < size; i++)
	{
		std::cout << tmp[i];
		if (i != size - 1)
			std::cout << ",";
	}
	std::cout << std::endl;
	free(tmp);
}

// PARTICLE SYSTEM //

__global__ void initializeDevFloat(float * devArr, const int numParticles, const float value, const int offset)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i >= numParticles) { return; }
	devArr[i + offset] = value;
}

__global__ void initializeDevFloat3(float3 * devArr, const int numParticles, const float3 val, const int offset)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i >= numParticles) { return; }
	devArr[i + offset] = val;
}

__global__ void initializeBlockPosition(float3 * positions, const int numParticles, const int3 dimension, const float3 startPosition, const float3 step, const int offset)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i >= numParticles) { return; }
	int x = i % dimension.x;
	int y = (i / dimension.x) % dimension.y;
	int z = i / (dimension.x * dimension.y);
	positions[i + offset] = make_float3(x, y, z) * step + startPosition;
}

// SOLVER //

__global__ void applyForces(float3 * velocities, float * invMass, const int numParticles, const float deltaTime)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i >= numParticles) { return; }
	velocities[i] += make_float3(0.0f, -9.8f, 0.0f) * deltaTime;
}

__global__ void predictPositions(float3 * newPositions, float3 * positions, float3 * velocities, const int numParticles, const float deltaTime)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i >= numParticles) { return; }
	newPositions[i] = positions[i] + velocities[i] * deltaTime;
}

__global__ void updateVelocity(float3 * velocities, float3 * newPositions, float3 * positions, const int numParticles, const float invDeltaTime)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i >= numParticles) { return; }
	velocities[i] = (newPositions[i] - positions[i]) * invDeltaTime;
}

__global__ void planeStabilize(float3 * positions, float3 * newPositions, const int numParticles, float3 planeOrigin, float3 planeNormal, const float radius)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i >= numParticles) { return; }
	float3 origin2position = planeOrigin - positions[i];
	float distance = dot(origin2position, planeNormal) + radius;
	if (distance <= 0) { return; }

	positions[i] += distance * planeNormal;
	newPositions[i] += distance * planeNormal;
}

__global__ void particlePlaneCollisionConstraint(float3 * newPositions, float3 * positions, const int numParticles, float3 planeOrigin, float3 planeNormal, const float radius)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i >= numParticles) { return; }
	float3 origin2position = planeOrigin - newPositions[i];
	float distance = dot(origin2position, planeNormal) + radius;
	if (distance <= 0) { return; }

	float diffPosition = dot(newPositions[i] - positions[i], planeNormal);
	newPositions[i] += distance * planeNormal;
	positions[i] += (2.0f * diffPosition + distance) * planeNormal / 10.0f;
}

__global__ void particleParticleCollisionConstraint(float3 * newPositionsNext, float3 * newPositionsPrev, const int numParticles, const float radius)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i >= numParticles) { return; }
	newPositionsNext[i] = newPositionsPrev[i];

	// query all neighbours and solve for collision
	for (int j = 0; j < numParticles; j++)
	{
		float3 diff = newPositionsPrev[i] - newPositionsPrev[j];
		float dist2 = length2(diff);
		if ((i != j) && (dist2 < radius * radius * 4.0f))
		{
			float dist = sqrtf(dist2);
			float3 normalizedDiff = diff / dist;
			float3 offset = diff * (0.5f - radius / dist);
			newPositionsNext[i] -= offset;
		}
	}
}

struct ParticleSolver
{
	ParticleSolver(const std::shared_ptr<Scene> & scene):
		scene(scene)
	{
		checkCudaErrors(cudaMalloc(&devPositions, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devNewPositions, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devTmpNewPositions, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devVelocities, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devInvMasses, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMalloc(&devDeltas, scene->numMaxParticles * sizeof(float3)));

		checkCudaErrors(cudaMemset(devPositions, 0, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMemset(devNewPositions, 0, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMemset(devTmpNewPositions, 0, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMemset(devVelocities, 0, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMemset(devInvMasses, 0, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMemset(devDeltas, 0, scene->numMaxParticles * sizeof(float3)));
	}

	void addParticles(const glm::ivec3 & dimension, const glm::vec3 & startPosition, const glm::vec3 & step, const float mass)
	{
		int numParticles = dimension.x * dimension.y * dimension.z;

		// check if number of particles exceed num max particles or not
		if (scene->numParticles + numParticles > scene->numMaxParticles)
		{
			std::string message = std::string(__FILE__) + std::string(" num particles exceed num max particles");
			throw std::exception(message.c_str());
		}

		int numBlocks, numThreads;
		GetNumBlocksNumThreads(&numBlocks, &numThreads, numParticles);

		initializeDevFloat<<<numBlocks, numThreads>>>(devInvMasses, numParticles, 1.0f / mass, scene->numParticles);
		initializeBlockPosition<<<numBlocks, numThreads>>>(devPositions, numParticles, make_int3(dimension), make_float3(startPosition), make_float3(step), scene->numParticles);
		//initializeBlockPosition<<<1, numParticles>>>(devNewPositions, make_int3(dimension), make_float3(startPosition), make_float3(step), scene->numParticles);
		scene->numParticles += numParticles;
	}

	void update(const int numSubTimeStep, const float deltaTime)
	{
		float subDeltaTime = deltaTime / (float)numSubTimeStep;
		int numBlocks, numThreads;
		GetNumBlocksNumThreads(&numBlocks, &numThreads, scene->numParticles);
		for (int i = 0;i < numSubTimeStep;i++)
		{ 
			applyForces<<<numBlocks, numThreads>>>(devVelocities, devInvMasses, scene->numParticles, subDeltaTime);
			predictPositions<<<numBlocks, numThreads>>>(devNewPositions, devPositions, devVelocities, scene->numParticles, subDeltaTime);

			// stabilize iterations
			for (int i = 0; i < 2; i++)
			{
				for (const Plane & plane : scene->planes)
				{
					planeStabilize<<<numBlocks, numThreads>>>(devPositions, devNewPositions, scene->numParticles, make_float3(plane.origin), make_float3(plane.normal), scene->radius);
				}
			}

			// projecting constraints iterations
			for (int i = 0; i < 10; i++)
			{
				// solving all plane collisions
				for (const Plane & plane : scene->planes)
				{
					particlePlaneCollisionConstraint<<<numBlocks, numThreads>>>(devNewPositions, devPositions, scene->numParticles, make_float3(plane.origin), make_float3(plane.normal), scene->radius);
				}

				// solving all particles collisions
				particleParticleCollisionConstraint<<<numBlocks, numThreads>>>(devTmpNewPositions, devNewPositions, scene->numParticles, scene->radius);
				std::swap(devTmpNewPositions, devNewPositions);
			}

			updateVelocity<<<1, scene->numParticles>>>(devVelocities, devNewPositions, devPositions, scene->numParticles, 1.0f / subDeltaTime);
			std::swap(devNewPositions, devPositions); // update position

			//cudaDeviceSynchronize(); for printf
		}
	}

	~ParticleSolver()
	{
		checkCudaErrors(cudaFree(devPositions));
		checkCudaErrors(cudaFree(devNewPositions));
		checkCudaErrors(cudaFree(devTmpNewPositions));
		checkCudaErrors(cudaFree(devVelocities));
		checkCudaErrors(cudaFree(devInvMasses));
		checkCudaErrors(cudaFree(devDeltas));
	}

	// particle system data
	float3 *devPositions;
	float3 *devVelocities;
	float3 *devNewPositions;
	float3 *devTmpNewPositions;
	float *devInvMasses;

	// 2 buffers
	float3 *devDeltas;

	std::shared_ptr<Scene> scene;
};