--[[
	Advanced Physics-Based Movement Controller
	Demonstrates: Vector Math, Linear Algebra (Reflection), Spatial Querying, 
	ContextActionService, and Custom Physics manipulation.
]]

local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Character = script.Parent
local Humanoid = Character:WaitForChild("Humanoid") :: Humanoid
local Root = Character:WaitForChild("HumanoidRootPart") :: BasePart
local Camera = workspace.CurrentCamera

-- CONFIGURATION & TUNING
local CLICK_FORCE = 35
local DASH_MULTIPLIER = 10
local MAX_SPEED = 150
local RAY_DISTANCE = 1000
local TETHER_RANGE = 300
local REEL_SPEED = 5

local CLICK_COOLDOWN = 0.05
local DASH_COOLDOWN = 1.5

local BASE_FOV = 70
local MAX_FOV = 100

local BASE_DECELERATION = 40
local SPEED_FACTOR = 0.5
local BOUNCE_ELASTICITY = 0.7
local SLAM_SPEED = 200
local SHOCKWAVE_RADIUS = 30
local SHOCKWAVE_FORCE = 1500

-- STATE TRACKING
local lastClickTime = 0
local lastDashTime = 0

local decelerateConnection: RBXScriptConnection? = nil
local inStasis = false
local isSlamming = false
local isTethered = false

-- ANTI-GRAVITY & PHYSICS SETUP
local Attachment = script:WaitForChild("Attachment") :: Attachment
local VectorForce = Attachment:WaitForChild("VectorForce") :: VectorForce

local tetherAttachment = Instance.new("Attachment")
tetherAttachment.Name = "TetherPoint"
tetherAttachment.Parent = workspace.Terrain

local ropeConstraint = Instance.new("RopeConstraint")
ropeConstraint.Visible = false
ropeConstraint.Enabled = false
ropeConstraint.Thickness = 0.15
ropeConstraint.Color = BrickColor.new("Cyan")
ropeConstraint.Attachment0 = Attachment
ropeConstraint.Attachment1 = tetherAttachment
ropeConstraint.Parent = Root

-- Apply an upward VectorForce to exactly counteract workspace gravity based on AssemblyMass
Attachment.Parent = Root
VectorForce.Attachment0 = Attachment
VectorForce.Force = Vector3.new(0, Root.AssemblyMass * workspace.Gravity, 0)
Humanoid:ChangeState(Enum.HumanoidStateType.Physics)

-- SPATIAL QUERY PARAMETERS
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = {Character}

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.FilterDescendantsInstances = {Character}

-- Debug Visualizer for Raycast hits
local debugPart = Instance.new("Part")
debugPart.Anchored = true
debugPart.CanCollide = false
debugPart.CanQuery = false
debugPart.CanTouch = false
debugPart.Size = Vector3.one
debugPart.Material = Enum.Material.Neon
debugPart.Name = "ClickDebug"
debugPart.Parent = workspace

local function updateDebug(position: Vector3, color: Color3)
	debugPart.Position = position
	debugPart.Color = color
end

-- Generates a 3D coordinate from the player's 2D mouse screen position
local function getTargetPosition(): Vector3
	local mouseLocation = UserInputService:GetMouseLocation()
	local ray = Camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * RAY_DISTANCE, rayParams)

	-- Fallback to maximum ray distance if clicking into the sky void
	if result then
		return result.Position
	end
	return ray.Origin + (ray.Direction * RAY_DISTANCE)
end

-- Applies a directional impulse considering AssemblyMass to maintain consistent acceleration
local function applyImpulseToward(targetPosition: Vector3, directionSign: number, multiplier: number)
	local offset = targetPosition - Root.Position
	local magnitude = offset.Magnitude

	if magnitude <= 0.001 then return end

	local direction = offset / magnitude
	local impulse = direction * directionSign * Root.AssemblyMass * (CLICK_FORCE * multiplier)
	Root:ApplyImpulse(impulse)
end

-- Generates a fading trail part using TweenService
local function spawnDashTrail()
	local trailPart = Instance.new("Part")
	trailPart.Size = Root.Size
	trailPart.CFrame = Root.CFrame
	trailPart.Anchored = true
	trailPart.CanCollide = false
	trailPart.CanQuery = false
	trailPart.Material = Enum.Material.Neon
	trailPart.Color = Color3.fromRGB(0, 255, 255)
	trailPart.Parent = workspace

	local tweenInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(trailPart, tweenInfo, {Transparency = 1, Size = Vector3.zero})

	tween:Play()
	tween.Completed:Connect(function()
		trailPart:Destroy()
	end)
end

-- Calculates area-of-effect forces with linear falloff logic
local function createShockwave(position: Vector3)
	-- Visual Expansion
	local wave = Instance.new("Part")
	wave.Shape = Enum.PartType.Ball
	wave.Material = Enum.Material.ForceField
	wave.Color = Color3.fromRGB(255, 50, 50)
	wave.Anchored = true
	wave.CanCollide = false
	wave.CanQuery = false
	wave.Position = position
	wave.Size = Vector3.one
	wave.Parent = workspace

	local targetSize = Vector3.new(SHOCKWAVE_RADIUS * 2, SHOCKWAVE_RADIUS * 2, SHOCKWAVE_RADIUS * 2)
	local tweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
	local tween = TweenService:Create(wave, tweenInfo, {Size = targetSize, Transparency = 1})

	tween:Play()
	tween.Completed:Connect(function()
		wave:Destroy()
	end)

	-- Physics Application
	local partsInRadius = workspace:GetPartBoundsInRadius(position, SHOCKWAVE_RADIUS, overlapParams)
	for _, part in ipairs(partsInRadius) do
		if not part.Anchored and part.AssemblyMass > 0 then
			local forceDirection = (part.Position - position).Unit
			local distance = (part.Position - position).Magnitude
			local falloff = math.max(0, 1 - (distance / SHOCKWAVE_RADIUS))
			part:ApplyImpulse(forceDirection * part.AssemblyMass * SHOCKWAVE_FORCE * falloff)
		end
	end
end

-- DECELERATION CONTROLLER
local function stopDeceleration()
	if decelerateConnection then
		decelerateConnection:Disconnect()
		decelerateConnection = nil	
	end
end

local function startDeceleration()
	if decelerateConnection then return end

	decelerateConnection = RunService.Heartbeat:Connect(function(dt)
		local velocity = Root.AssemblyLinearVelocity
		local speed = velocity.Magnitude

		if speed > 0.1 then
			local deceleration = BASE_DECELERATION + (speed * SPEED_FACTOR)
			local newSpeed = math.max(speed - (deceleration * dt), 0)
			Root.AssemblyLinearVelocity = velocity.Unit * newSpeed
		else
			Root.AssemblyLinearVelocity = Vector3.zero
			stopDeceleration()
		end
	end)
end

-- CONTEXT ACTION HANDLERS
-- Returning Enum.ContextActionResult.Sink prevents inputs from bleeding through to other core scripts

local function handlePull(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end

	local now = os.clock()
	if now - lastClickTime < CLICK_COOLDOWN then return Enum.ContextActionResult.Pass end

	lastClickTime = now
	local targetPos = getTargetPosition()
	updateDebug(targetPos, Color3.fromRGB(0, 255, 255))
	applyImpulseToward(targetPos, 1, 1)

	return Enum.ContextActionResult.Sink
end

local function handlePush(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end

	local now = os.clock()
	if now - lastClickTime < CLICK_COOLDOWN then return Enum.ContextActionResult.Pass end

	lastClickTime = now
	local targetPos = getTargetPosition()
	updateDebug(targetPos, Color3.fromRGB(255, 0, 0))
	applyImpulseToward(targetPos, -1, 1) -- Negative direction inverts the impulse

	return Enum.ContextActionResult.Sink
end

local function handleDash(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end

	local now = os.clock()
	if now - lastDashTime < DASH_COOLDOWN then return Enum.ContextActionResult.Pass end

	lastDashTime = now
	spawnDashTrail()

	local targetPos = getTargetPosition()
	updateDebug(targetPos, Color3.fromRGB(255, 255, 0))
	applyImpulseToward(targetPos, 1, DASH_MULTIPLIER)

	return Enum.ContextActionResult.Sink
end

local function handleBrake(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if inputState == Enum.UserInputState.Begin then
		startDeceleration()
	elseif inputState == Enum.UserInputState.End then
		stopDeceleration()
	end
	return Enum.ContextActionResult.Sink
end

local function handleTether(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if inputState == Enum.UserInputState.Begin then
		local targetPos = getTargetPosition()
		local distance = (targetPos - Root.Position).Magnitude

		if distance <= TETHER_RANGE then
			tetherAttachment.WorldPosition = targetPos
			ropeConstraint.Length = distance
			ropeConstraint.Enabled = true
			ropeConstraint.Visible = true
			isTethered = true
		end
	elseif inputState == Enum.UserInputState.End then
		ropeConstraint.Enabled = false
		ropeConstraint.Visible = false
		isTethered = false
	end
	return Enum.ContextActionResult.Pass
end

local function handleReel(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if not isTethered then return Enum.ContextActionResult.Pass end

	-- Adjust RopeConstraint length based on mouse wheel scroll direction
	if inputObject.Position.Z > 0 then
		ropeConstraint.Length = math.max(ropeConstraint.Length - REEL_SPEED, 5)
	elseif inputObject.Position.Z < 0 then
		ropeConstraint.Length = math.min(ropeConstraint.Length + REEL_SPEED, TETHER_RANGE)
	end
	return Enum.ContextActionResult.Pass
end

local function handleStasis(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if inputState == Enum.UserInputState.Begin then
		inStasis = true
		Root.AssemblyLinearVelocity = Vector3.zero
	elseif inputState == Enum.UserInputState.End then
		inStasis = false
	end
	return Enum.ContextActionResult.Sink
end

local function handleSlam(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
	if isSlamming then return Enum.ContextActionResult.Pass end

	isSlamming = true
	-- Overwrite current velocity to force an immediate vertical descent
	Root.AssemblyLinearVelocity = Vector3.new(0, -SLAM_SPEED, 0)
	return Enum.ContextActionResult.Sink
end

-- RunService
local function processPhysics(dt: number)
	if inStasis then
		Root.AssemblyLinearVelocity = Vector3.zero
		return
	end

	local velocity = Root.AssemblyLinearVelocity
	local speed = velocity.Magnitude

	-- Clamp speed to terminal velocity to prevent physics engine desync/clipping
	if speed > MAX_SPEED then
		velocity = velocity.Unit * MAX_SPEED
		Root.AssemblyLinearVelocity = velocity
		speed = MAX_SPEED
	end

	-- Custom Continuous Collision Detection for high speeds
	if speed > 20 and not isSlamming then
		local predictionRay = workspace:Raycast(Root.Position, velocity.Unit * (speed * dt * 1.5), rayParams)
		if predictionRay then
			local normal = predictionRay.Normal
			local dotProduct = velocity:Dot(normal)
			local reflection = velocity - (2 * dotProduct * normal)
			Root.AssemblyLinearVelocity = reflection * BOUNCE_ELASTICITY
		end
	end
end

local function processSlamTick()
	if not isSlamming then return end

	-- Cast a short ray downwards to detect floor impact
	local hit = workspace:Raycast(Root.Position, Vector3.new(0, -Root.Size.Y - 2, 0), rayParams)
	if hit then
		isSlamming = false
		Root.AssemblyLinearVelocity = Vector3.zero
		createShockwave(hit.Position)
	end
end

local function processCamera(dt: number)
	-- Interpolate Camera FOV dynamically based on current velocity
	local speed = Root.AssemblyLinearVelocity.Magnitude
	local speedRatio = math.clamp(speed / MAX_SPEED, 0, 1)
	local targetFOV = BASE_FOV + (speedRatio * (MAX_FOV - BASE_FOV))

	Camera.FieldOfView = Camera.FieldOfView + (targetFOV - Camera.FieldOfView) * (dt * 5)
end

-- Bind all actions via ContextActionService
ContextActionService:BindAction("MovementPull", handlePull, false, Enum.UserInputType.MouseButton1)
ContextActionService:BindAction("MovementPush", handlePush, false, Enum.UserInputType.MouseButton2)
ContextActionService:BindAction("MovementDash", handleDash, false, Enum.KeyCode.LeftShift)
ContextActionService:BindAction("MovementBrake", handleBrake, false, Enum.KeyCode.Space)
ContextActionService:BindAction("MovementTether", handleTether, false, Enum.KeyCode.E)
ContextActionService:BindAction("MovementReel", handleReel, false, Enum.UserInputType.MouseWheel)
ContextActionService:BindAction("MovementStasis", handleStasis, false, Enum.KeyCode.Q)
ContextActionService:BindAction("MovementSlam", handleSlam, false, Enum.KeyCode.LeftControl)

-- Connect logic processors
RunService.Heartbeat:Connect(processPhysics)
RunService.Heartbeat:Connect(processSlamTick)
-- Use BindToRenderStep to ensure the camera FOV updates smoothly with frame renders
RunService:BindToRenderStep("DynamicFOV", Enum.RenderPriority.Camera.Value + 1, processCamera)
