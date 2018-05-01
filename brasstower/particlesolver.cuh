#pragma once

#include <exception>
#include <conio.h>

#include "solverkernel/util.cuh"
#include "solverkernel/grid.cuh"

#include "solverkernel/fluid.cuh"
#include "solverkernel/particleplane.cuh"
#include "solverkernel/particleparticle.cuh"
#include "solverkernel/shapematching.cuh"

// SOLVER //

__global__ void
applyForces(float3 * __restrict__ velocities,
			const float * __restrict__ invMass,
			const int numParticles,
			const float deltaTime)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }
	velocities[i] += make_float3(0.0f, -9.8f, 0.0f) * deltaTime;
}

__global__ void
predictPositions(float3 * __restrict__ newPositions,
				 const float3 * __restrict__ positions,
				 const float3 * __restrict__ velocities,
				 const int numParticles,
				 const float deltaTime)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }
	newPositions[i] = positions[i] + velocities[i] * deltaTime;
}

__global__ void
updateVelocity(float3 * __restrict__ velocities,
			   const float3 * __restrict__ newPositions,
			   const float3 * __restrict__ positions,
			   const int numParticles,
			   const float invDeltaTime)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }
	velocities[i] = (newPositions[i] - positions[i]) * invDeltaTime;
}

// for shock propagation
__global__ void
computeInvScaledMasses(float* __restrict__ invScaledMasses,
					   const float* __restrict__ masses,
					   const float3* __restrict__ positions,
					   const float k,
					   const int numParticles)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }

	const float e = 2.7182818284f;
	const float height = positions[i].y;
	const float scale = pow(e, -k * height);
	invScaledMasses[i] = 1.0f / (scale * masses[i]);
}

__global__ void
updatePositions(float3 * __restrict__ positions,
				const float3 * __restrict__ newPositions,
				const int * __restrict__ phases,
				const float threshold,
				const int numParticles)
{
	int i = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	if (i >= numParticles) { return; }

	const int phase = phases[i];
	const float3 x = positions[i];
	const float3 newX = newPositions[i];

	const float dist2 = length2(newX - x);
	positions[i] = (dist2 >= threshold * threshold || phases[i] < 0) ? newX : x;
}

struct ParticleSolver
{
	ParticleSolver(const std::shared_ptr<Scene> & scene):
		scene(scene),
		cellOrigin(make_float3(-4.01, -1.01, -5.01)),
		cellSize(make_float3(scene->radius * 2.3f)),
		gridSize(make_int3(512))
	{
		fluidKernelRadius = 2.3f * scene->radius;
		SetKernelRadius(fluidKernelRadius);

		// alloc particle vars
		checkCudaErrors(cudaMalloc(&devPositions, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devNewPositions, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devTempFloat3, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devVelocities, scene->numMaxParticles * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devMasses, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMalloc(&devInvMasses, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMalloc(&devInvScaledMasses, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMalloc(&devPhases, scene->numMaxParticles * sizeof(int)));
		checkCudaErrors(cudaMalloc(&devOmegas, scene->numMaxParticles * sizeof(float3)));

		// set velocity
		checkCudaErrors(cudaMemset(devVelocities, 0, scene->numMaxParticles * sizeof(float3)));

		// alloc rigid body
		checkCudaErrors(cudaMalloc(&devRigidBodyParticleIdRange, scene->numMaxRigidBodies * sizeof(int2)));
		checkCudaErrors(cudaMalloc(&devRigidBodyCMs, scene->numMaxRigidBodies * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devRigidBodyInitialPositions, scene->numMaxRigidBodies * NUM_MAX_PARTICLE_PER_RIGID_BODY * sizeof(float3)));
		checkCudaErrors(cudaMalloc(&devRigidBodyRotations, scene->numMaxRigidBodies * sizeof(quaternion)));
		int numBlocksRigidBody, numThreadsRigidBody;
		GetNumBlocksNumThreads(&numBlocksRigidBody, &numThreadsRigidBody, scene->numMaxRigidBodies);
		setDevArr_float4<<<numBlocksRigidBody, numThreadsRigidBody>>>(devRigidBodyRotations, make_float4(0, 0, 0, 1), scene->numMaxRigidBodies);

		// alloc and set phase counter
		checkCudaErrors(cudaMalloc(&devSolidPhaseCounter, sizeof(int)));
		checkCudaErrors(cudaMemset(devSolidPhaseCounter, 1, sizeof(int)));

		// alloc grid accel
		checkCudaErrors(cudaMalloc(&devCellId, scene->numMaxParticles * sizeof(int)));
		checkCudaErrors(cudaMalloc(&devParticleId, scene->numMaxParticles * sizeof(int)));
		checkCudaErrors(cudaMalloc(&devSortedCellId, scene->numMaxParticles * sizeof(int)));
		checkCudaErrors(cudaMalloc(&devSortedParticleId, scene->numMaxParticles * sizeof(int)));
		checkCudaErrors(cudaMalloc(&devCellStart, gridSize.x * gridSize.y * gridSize.z * sizeof(int)));

		// alloc fluid vars
		checkCudaErrors(cudaMalloc(&devFluidLambdas, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMalloc(&devFluidDensities, scene->numMaxParticles * sizeof(float)));
		checkCudaErrors(cudaMalloc(&devFluidNormals, scene->numMaxParticles * sizeof(float3)));

		// start initing the scene
		for (std::shared_ptr<RigidBody> rigidBody : scene->rigidBodies)
		{
			addRigidBody(rigidBody->positions, rigidBody->positions_CM_Origin, rigidBody->massPerParticle);
		}

		for (std::shared_ptr<Granulars> granulars : scene->granulars)
		{
			addGranulars(granulars->positions, granulars->massPerParticle);
		}

		for (std::shared_ptr<Fluid> fluids : scene->fluids)
		{
			addFluids(fluids->positions, fluids->massPerParticle);
		}

		fluidRestDensity = scene->fluidRestDensity;
	}

	void updateTempStorageSize(const size_t size)
	{
		if (size > devTempStorageSize)
		{
			if (devTempStorage != nullptr) { checkCudaErrors(cudaFree(devTempStorage)); }
			checkCudaErrors(cudaMalloc(&devTempStorage, size));
			devTempStorageSize = size;
		}
	}

	glm::vec3 getParticlePosition(const int particleIndex)
	{
		if (particleIndex < 0 || particleIndex >= scene->numParticles) return glm::vec3(0.0f);
		float3 * tmp = (float3 *)malloc(sizeof(float3));
		cudaMemcpy(tmp, devPositions + particleIndex, sizeof(float3), cudaMemcpyDeviceToHost);
		glm::vec3 result(tmp->x, tmp->y, tmp->z);
		free(tmp);
		return result;
	}

	void setParticle(const int particleIndex, const glm::vec3 & position, const glm::vec3 & velocity)
	{
		if (particleIndex < 0 || particleIndex >= scene->numParticles) return;
		setDevArr_float3<<<1, 1>>>(devPositions + particleIndex, make_float3(position.x, position.y, position.z), 1);
		setDevArr_float3<<<1, 1>>>(devVelocities + particleIndex, make_float3(velocity.x, velocity.y, velocity.z), 1);
	}

	void addGranulars(const std::vector<glm::vec3> & positions, const float massPerParticle)
	{
		int numParticles = positions.size();
		if (scene->numParticles + numParticles >= scene->numMaxParticles)
		{
			std::string message = std::string(__FILE__) + std::string("num particles exceed num max particles");
			throw std::exception(message.c_str());
		}

		int numBlocks, numThreads;
		GetNumBlocksNumThreads(&numBlocks, &numThreads, numParticles);

		// set positions
		checkCudaErrors(cudaMemcpy(devPositions + scene->numParticles,
								   &(positions[0].x),
								   numParticles * sizeof(float) * 3,
								   cudaMemcpyHostToDevice));
		// set masses
		setDevArr_float<<<numBlocks, numThreads>>>(devMasses + scene->numParticles,
												   massPerParticle,
												   numParticles);	
		// set invmasses
		setDevArr_float<<<numBlocks, numThreads>>>(devInvMasses + scene->numParticles,
												   1.0f / massPerParticle,
												   numParticles);
		// set phases
		setDevArr_counterIncrement<<<numBlocks, numThreads>>>(devPhases + scene->numParticles,
															  devSolidPhaseCounter,
															  1,
															  numParticles);
		scene->numParticles += numParticles;
	}

	void addRigidBody(const std::vector<glm::vec3> & initialPositions, const std::vector<glm::vec3> & initialPositions_CM_Origin, const float massPerParticle)
	{
		int numParticles = initialPositions.size();
		if (scene->numParticles + numParticles >= scene->numMaxParticles)
		{
			std::string message = std::string(__FILE__) + std::string("num particles exceed num max particles");
			throw std::exception(message.c_str());
		}

		if (scene->numRigidBodies + 1 >= scene->numMaxRigidBodies)
		{
			std::string message = std::string(__FILE__) + std::string("num rigid bodies exceed num max rigid bodies");
			throw std::exception(message.c_str());
		}

		glm::vec3 cm = glm::vec3(0.0f);
		for (const glm::vec3 & position : initialPositions_CM_Origin) { cm += position; }
		cm /= (float)initialPositions_CM_Origin.size();

		if (glm::length(cm) >= 1e-5f)
		{
			std::string message = std::string(__FILE__) + std::string("expected Center of Mass at the origin");
			throw std::exception(message.c_str());
		}

		// set positions
		checkCudaErrors(cudaMemcpy(devPositions + scene->numParticles,
								   &(initialPositions[0].x),
								   numParticles * sizeof(float) * 3,
								   cudaMemcpyHostToDevice));
		checkCudaErrors(cudaMemcpy(devRigidBodyInitialPositions + scene->numParticles,
								   &(initialPositions_CM_Origin[0].x),
								   numParticles * sizeof(float) * 3,
								   cudaMemcpyHostToDevice));
		int numBlocks, numThreads;
		GetNumBlocksNumThreads(&numBlocks, &numThreads, numParticles);

		// set masses
		setDevArr_float<<<numBlocks, numThreads>>>(devMasses + scene->numParticles,
												   massPerParticle,
												   numParticles);

		// set inv masses
		setDevArr_float<<<numBlocks, numThreads>>>(devInvMasses + scene->numParticles,
												   1.0f / massPerParticle,
												   numParticles);
		// set phases
		setDevArr_devIntPtr<<<numBlocks, numThreads>>>(devPhases + scene->numParticles,
													   devSolidPhaseCounter,
													   numParticles);
		// set range for particle id
		setDevArr_int2<<<1, 1>>>(devRigidBodyParticleIdRange + scene->numRigidBodies,
								 make_int2(scene->numParticles, scene->numParticles + numParticles),
								 1);
		// increment phase counter
		increment<<<1, 1>>>(devSolidPhaseCounter);
		
		scene->numParticles += numParticles;
		scene->numRigidBodies += 1;
	}

	void addFluids(const std::vector<glm::vec3> & positions, const float massPerParticle)
	{
		int numParticles = positions.size();
		if (scene->numParticles + numParticles >= scene->numMaxParticles)
		{
			std::string message = std::string(__FILE__) + std::string("num particles exceed num max particles");
			throw std::exception(message.c_str());
		}

		int numBlocks, numThreads;
		GetNumBlocksNumThreads(&numBlocks, &numThreads, numParticles);

		// set positions
		checkCudaErrors(cudaMemcpy(devPositions + scene->numParticles,
								   &(positions[0].x),
								   numParticles * sizeof(float) * 3,
								   cudaMemcpyHostToDevice));
		// set masses
		setDevArr_float<<<numBlocks, numThreads>>>(devMasses + scene->numParticles,
												   massPerParticle,
												   numParticles);	
		// set invmasses
		setDevArr_float<<<numBlocks, numThreads>>>(devInvMasses + scene->numParticles,
												   1.0f / massPerParticle,
												   numParticles);
		// fluid phase is always -1
		setDevArr_int<<<numBlocks, numThreads>>>(devPhases + scene->numParticles,
												 -1,
												 numParticles);
		scene->numParticles += numParticles;
	}

	void updateGrid(int numBlocks, int numThreads)
	{
		setDevArr_int<<<numBlocks, numThreads>>>(devCellStart, -1, scene->numMaxParticles);
		updateGridId<<<numBlocks, numThreads>>>(devCellId,
												devParticleId,
												devNewPositions,
												cellOrigin,
												cellSize,
												gridSize,
												scene->numParticles);
		size_t tempStorageSize = 0;
		// get temp storage size (not sorting yet)
		cub::DeviceRadixSort::SortPairs(NULL,
										tempStorageSize,
										devCellId,
										devSortedCellId,
										devParticleId,
										devSortedParticleId,
										scene->numParticles);
		updateTempStorageSize(tempStorageSize);
		// sort!
		cub::DeviceRadixSort::SortPairs(devTempStorage,
										devTempStorageSize,
										devCellId,
										devSortedCellId,
										devParticleId,
										devSortedParticleId,
										scene->numParticles);
		findStartId<<<numBlocks, numThreads>>>(devCellStart, devSortedCellId, scene->numParticles);
	}

	void update(const int numSubTimeStep,
				const float deltaTime,
				const int pickedParticleId = -1,
				const glm::vec3 & pickedParticlePosition = glm::vec3(0.0f),
				const glm::vec3 & pickedParticleVelocity = glm::vec3(0.0f))
	{
		float subDeltaTime = deltaTime / (float)numSubTimeStep;
		int numBlocks, numThreads;
		GetNumBlocksNumThreads(&numBlocks, &numThreads, scene->numParticles);

		int3 fluidGridSearchOffset = make_int3(ceil(make_float3(fluidKernelRadius) / cellSize));
		bool useAkinciCohesionTension = true;

		for (int i = 0;i < numSubTimeStep;i++)
		{ 
			applyForces<<<numBlocks, numThreads>>>(devVelocities,
												   devInvMasses,
												   scene->numParticles,
												   subDeltaTime);

			// we need to make picked particle immovable
			if (pickedParticleId >= 0 && pickedParticleId < scene->numParticles)
			{
				setParticle(pickedParticleId, pickedParticlePosition, glm::vec3(0.0f));
			}

			predictPositions<<<numBlocks, numThreads>>>(devNewPositions,
														devPositions,
														devVelocities,
														scene->numParticles,
														subDeltaTime);


			// compute scaled masses
			computeInvScaledMasses<<<numBlocks, numThreads>>>(devInvScaledMasses,
															  devMasses,
															  devPositions,
															  MASS_SCALING_CONSTANT,
															  scene->numParticles);

			// stabilize iterations
			for (int i = 0; i < 2; i++)
			{
				for (const Plane & plane : scene->planes)
				{
					planeStabilize<<<numBlocks, numThreads>>>(devPositions,
															  devNewPositions,
															  scene->numParticles,
															  make_float3(plane.origin),
															  make_float3(plane.normal),
															  scene->radius);
				}
			}

			// projecting constraints iterations
			// (update grid every n iterations)
			for (int i = 0; i < 1; i++)
			{
				// compute grid
				updateGrid(numBlocks, numThreads);

				for (int j = 0; j < 2; j++)
				{
					// solving all plane collisions
					for (const Plane & plane : scene->planes)
					{
						particlePlaneCollisionConstraint<<<numBlocks, numThreads>>>(devNewPositions,
																					devPositions,
																					scene->numParticles,
																					make_float3(plane.origin),
																					make_float3(plane.normal),
																					scene->radius);
					}

					/*// solving all particles collisions
					particleParticleCollisionConstraint<<<numBlocks, numThreads>>>(devTempNewPositions,
																				   devNewPositions,
																				   devPositions,
																				   devInvScaledMasses,
																				   devPhases,
																				   devSortedCellId,
																				   devSortedParticleId,
																				   devCellStart,
																				   cellOrigin,
																				   cellSize,
																				   gridSize,
																				   scene->numParticles,
																				   scene->radius);*/
					//std::swap(devTempNewPositions, devNewPositions);

					// fluid
					fluidLambda<<<numBlocks, numThreads>>>(devFluidLambdas,
														   devFluidDensities,
														   devNewPositions,
														   devMasses,
														   devPhases,
														   fluidRestDensity,
														   300.0f, // relaxation parameter
														   devSortedCellId,
														   devSortedParticleId,
														   devCellStart,
														   cellOrigin,
														   cellSize,
														   gridSize,
														   fluidGridSearchOffset,
														   scene->numParticles,
														   useAkinciCohesionTension);
					fluidPosition<<<numBlocks, numThreads>>>(devTempFloat3,
															 devNewPositions,
															 devFluidLambdas,
															 fluidRestDensity,
															 devPhases,
															 0.0001f, // k for sCorr
															 4, // N for sCorr
															 devSortedCellId,
															 devSortedParticleId,
															 devCellStart,
															 cellOrigin,
															 cellSize,
															 gridSize,
															 fluidGridSearchOffset,
															 scene->numParticles,
															 useAkinciCohesionTension);
					std::swap(devTempFloat3, devNewPositions);

					// solve all rigidbody constraints
					if (scene->numRigidBodies > 0)
					{ 
						shapeMatchingAlphaOne<<<scene->numRigidBodies, NUM_MAX_PARTICLE_PER_RIGID_BODY>>>(devRigidBodyRotations,
																										  devRigidBodyCMs,
																										  devNewPositions,
																										  devRigidBodyInitialPositions,
																										  devRigidBodyParticleIdRange);
					}
				}
			}

			updateVelocity<<<numBlocks, numThreads>>>(devVelocities,
													  devNewPositions,
													  devPositions,
													  scene->numParticles,
													  1.0f / subDeltaTime);

			updatePositions<<<numBlocks, numThreads>>>(devPositions, devNewPositions, devPhases, PARTICLE_SLEEPING_EPSILON, scene->numParticles);

			// vorticity confinement part 1.
			fluidOmega<<<numBlocks, numThreads>>>(devOmegas,
												  devVelocities,
												  devNewPositions,
												  devPhases,
												  devSortedCellId,
												  devSortedParticleId,
												  devCellStart,
												  cellOrigin,
												  cellSize,
												  gridSize,
												  fluidGridSearchOffset,
												  scene->numParticles);

			// vorticity confinement part 2.
			fluidVorticity<<<numBlocks, numThreads>>>(devVelocities,
													  devOmegas,
													  devNewPositions,
													  0.001f, // epsilon in eq. 16
													  devPhases,
													  devSortedCellId,
													  devSortedParticleId,
													  devCellStart,
													  cellOrigin,
													  cellSize,
													  gridSize,
													  fluidGridSearchOffset,
													  scene->numParticles,
													  subDeltaTime);

			if (useAkinciCohesionTension)
			{ 
				// fluid normal for Akinci cohesion
				fluidNormal<<<numBlocks, numThreads>>>(devFluidNormals,
													   devNewPositions,
													   devFluidDensities,
													   devPhases,
													   devSortedCellId,
													   devSortedParticleId,
													   devCellStart,
													   cellOrigin,
													   cellSize,
													   gridSize,
													   fluidGridSearchOffset,
													   scene->numParticles);

				fluidAkinciTension<<<numBlocks, numThreads>>>(devTempFloat3,
															  devVelocities,
															  devNewPositions,
															  devFluidNormals,
															  devFluidDensities,
															  fluidRestDensity,
															  devPhases,
															  0.6, // tension strength
															  devSortedCellId,
															  devSortedParticleId,
															  devCellStart,
															  cellOrigin,
															  cellSize,
															  gridSize,
															  fluidGridSearchOffset,
															  scene->numParticles,
															  deltaTime);
				std::swap(devVelocities, devTempFloat3);
			}

			// xsph
			fluidXSph<<<numBlocks, numThreads>>>(devTempFloat3,
												 devVelocities,
												 devNewPositions,
												 0.0002f, // C in eq. 17
												 devPhases,
												 devSortedCellId,
												 devSortedParticleId,
												 devCellStart,
												 cellOrigin,
												 cellSize,
												 gridSize,
												 fluidGridSearchOffset,
												 scene->numParticles);
			std::swap(devVelocities, devTempFloat3);
		}

		// we need to make picked particle immovable
		if (pickedParticleId >= 0 && pickedParticleId < scene->numParticles)
		{
			glm::vec3 solvedPickedParticlePosition = getParticlePosition(pickedParticleId);
			setParticle(pickedParticleId, solvedPickedParticlePosition, pickedParticleVelocity);
		}
	}

	/// TODO:: implement object's destroyer

	float3 *	devPositions;
	float3 *	devNewPositions;
	float3 *	devTempFloat3;
	float3 *	devVelocities;
	float *		devMasses;
	float *		devInvMasses;
	float *		devInvScaledMasses;
	int *		devPhases;
	int *		devSolidPhaseCounter;
	float3 *	devOmegas;

	float *		devFluidLambdas;
	float *		devFluidDensities;
	float3 *	devFluidNormals;
	int *		devFluidNeighboursIds;
	float		fluidKernelRadius;
	float		fluidRestDensity;

	int *		devSortedCellId;
	int *		devSortedParticleId;

	int2 *		devRigidBodyParticleIdRange;
	float3 *	devRigidBodyInitialPositions;
	quaternion * devRigidBodyRotations;
	float3 *	devRigidBodyCMs;// center of mass

	void *		devTempStorage = nullptr;
	size_t		devTempStorageSize = 0;

	int *			devCellId;
	int *			devParticleId;
	int *			devCellStart;
	const float3	cellOrigin;
	const float3	cellSize;
	const int3		gridSize;

	std::shared_ptr<Scene> scene;
};