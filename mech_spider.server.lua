--[[
Mech Spider Controller (Server Script)

Place this Script inside your Mech model (recommended) or ServerScriptService.

Model requirements:
- A Model named "Mech" (or script.Parent is the Mech model)
- PrimaryPart set (or a Part named "Body")
- A VehicleSeat somewhere in the model
- A Folder named "Legs" containing leg Models

Each leg Model should have BaseParts named (case-insensitive):
  Hip, Thigh, Calf
Optional: Foot (BasePart)

Motor6D chain (can be named however you want):
  Body <-> Hip, Hip <-> Thigh, Thigh <-> Calf

Optional per-leg Attributes (numbers):
  UpperLength, LowerLength
  YawSign (default 1)
  ForwardSign (default -1, because LookVector is -Z)
  HipPitchSign (default 1)
  KneePitchSign (default 1)
  YawOffsetDegrees, HipPitchOffsetDegrees, KneePitchOffsetDegrees

Optional mech Model Attributes (numbers):
  MaxSpeed, Acceleration, TurnSpeedDeg
  StepLength, StepHeight, StepTrigger, StepDuration
  GaitSpeed, StepWindow, RayHeight, RayDistance, FootLift
  UprightResponsiveness
Optional mech Model Attributes (bool):
  KeepUpright
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local function warnf(fmt, ...)
	warn(string.format(fmt, ...))
end

local function getBoolAttr(inst, name, defaultValue)
	local value = inst:GetAttribute(name)
	if typeof(value) == "boolean" then
		return value
	end
	return defaultValue
end

local function getNumberAttr(inst, name, defaultValue)
	local value = inst:GetAttribute(name)
	if typeof(value) == "number" then
		return value
	end
	return defaultValue
end

local function findDescendantByName(root, name, className)
	local lower = string.lower(name)
	for _, desc in ipairs(root:GetDescendants()) do
		if string.lower(desc.Name) == lower and (not className or desc:IsA(className)) then
			return desc
		end
	end
	return nil
end

local function findMotorBetween(root, partA, partB)
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("Motor6D") then
			if (desc.Part0 == partA and desc.Part1 == partB) or (desc.Part0 == partB and desc.Part1 == partA) then
				return desc
			end
		end
	end
	return nil
end

local mech = script.Parent
if not mech or not mech:IsA("Model") then
	mech = Workspace:WaitForChild("Mech")
end

local body = mech.PrimaryPart or mech:FindFirstChild("Body", true)
if not body or not body:IsA("BasePart") then
	error("Mech needs PrimaryPart or a BasePart named Body.")
end
mech.PrimaryPart = body

local seat = mech:FindFirstChildWhichIsA("VehicleSeat", true)
if not seat then
	error("Mech needs a VehicleSeat.")
end

local legsFolder = mech:FindFirstChild("Legs")
if not legsFolder then
	error("Mech needs a Folder named Legs.")
end

local config = {
	MaxSpeed = getNumberAttr(mech, "MaxSpeed", 24),
	Acceleration = getNumberAttr(mech, "Acceleration", 18),
	TurnSpeed = math.rad(getNumberAttr(mech, "TurnSpeedDeg", 80)),
	StepLength = getNumberAttr(mech, "StepLength", 6),
	StepHeight = getNumberAttr(mech, "StepHeight", 2.5),
	StepTrigger = getNumberAttr(mech, "StepTrigger", 4),
	StepDuration = getNumberAttr(mech, "StepDuration", 0.22),
	GaitSpeed = getNumberAttr(mech, "GaitSpeed", 2.0),
	StepWindow = getNumberAttr(mech, "StepWindow", 0.35),
	RayHeight = getNumberAttr(mech, "RayHeight", 8),
	RayDistance = getNumberAttr(mech, "RayDistance", 18),
	FootLift = getNumberAttr(mech, "FootLift", 0.1),
	KeepUpright = getBoolAttr(mech, "KeepUpright", true),
	UprightResponsiveness = getNumberAttr(mech, "UprightResponsiveness", 10),
}

local gaitOffsets = {
	RightFrontLeg = 0,
	LeftBackLeg = 0,
	LeftFrontLeg = 0.5,
	RightBackLeg = 0.5,
}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { mech }

local rootAttachment = body:FindFirstChild("MechRootAttachment")
if not rootAttachment then
	rootAttachment = Instance.new("Attachment")
	rootAttachment.Name = "MechRootAttachment"
	rootAttachment.Parent = body
end

local moveForce = body:FindFirstChild("MechMoveForce")
if not moveForce then
	moveForce = Instance.new("VectorForce")
	moveForce.Name = "MechMoveForce"
	moveForce.RelativeTo = Enum.ActuatorRelativeTo.World
	moveForce.ApplyAtCenterOfMass = true
	moveForce.Attachment0 = rootAttachment
	moveForce.Parent = body
end

local turnTorque = body:FindFirstChild("MechTurnTorque")
if not turnTorque then
	turnTorque = Instance.new("AngularVelocity")
	turnTorque.Name = "MechTurnTorque"
	turnTorque.RelativeTo = Enum.ActuatorRelativeTo.World
	turnTorque.MaxTorque = math.huge
	turnTorque.Attachment0 = rootAttachment
	turnTorque.Parent = body
end

local uprightAlign = body:FindFirstChild("MechUprightAlign")
if not uprightAlign then
	uprightAlign = Instance.new("AlignOrientation")
	uprightAlign.Name = "MechUprightAlign"
	uprightAlign.Mode = Enum.OrientationAlignmentMode.OneAttachment
	uprightAlign.Attachment0 = rootAttachment
	uprightAlign.Responsiveness = config.UprightResponsiveness
	uprightAlign.RigidityEnabled = false
	uprightAlign.Parent = body
end

local function computeFootFromCalf(calfPart)
	local offset = Vector3.new(0, -calfPart.Size.Y * 0.5, 0)
	return (calfPart.CFrame * CFrame.new(offset)).Position
end

local function buildLeg(legModel, index, totalLegs)
	if not legModel:IsA("Model") then
		return nil
	end

	local hip = findDescendantByName(legModel, "hip", "BasePart")
	local thigh = findDescendantByName(legModel, "thigh", "BasePart")
	local calf = findDescendantByName(legModel, "calf", "BasePart")
	local foot = findDescendantByName(legModel, "foot", "BasePart")

	if not hip or not thigh or not calf then
		warnf("Leg %s missing hip/thigh/calf parts.", legModel.Name)
		return nil
	end

	local hipMotor = findMotorBetween(mech, body, hip) or findDescendantByName(legModel, "hipmotor", "Motor6D")
	local thighMotor = findMotorBetween(mech, hip, thigh) or findDescendantByName(legModel, "thighmotor", "Motor6D")
	local calfMotor = findMotorBetween(mech, thigh, calf) or findDescendantByName(legModel, "calfmotor", "Motor6D")

	if not hipMotor or not thighMotor or not calfMotor then
		warnf("Leg %s missing Motor6D chain (hip/thigh/calf).", legModel.Name)
		return nil
	end

	local upperLen = getNumberAttr(legModel, "UpperLength", thigh.Size.Y)
	local lowerLen = getNumberAttr(legModel, "LowerLength", calf.Size.Y)

	local footWorld = foot and foot.Position or computeFootFromCalf(calf)

	local phaseOffset = gaitOffsets[legModel.Name]
	if phaseOffset == nil then
		phaseOffset = (index - 1) / math.max(totalLegs, 1)
	end

	return {
		model = legModel,
		hip = hip,
		thigh = thigh,
		calf = calf,
		foot = foot,
		hipMotor = hipMotor,
		thighMotor = thighMotor,
		calfMotor = calfMotor,
		hipBaseTransform = hipMotor.Transform,
		thighBaseTransform = thighMotor.Transform,
		calfBaseTransform = calfMotor.Transform,
		upperLen = upperLen,
		lowerLen = lowerLen,
		phaseOffset = phaseOffset,
		currentFootWorld = footWorld,
		stepFrom = footWorld,
		stepTo = footWorld,
		stepStart = 0,
		isStepping = false,
		defaultFootLocal = body.CFrame:PointToObjectSpace(footWorld),
		yawSign = getNumberAttr(legModel, "YawSign", 1),
		forwardSign = getNumberAttr(legModel, "ForwardSign", -1),
		hipPitchSign = getNumberAttr(legModel, "HipPitchSign", 1),
		kneePitchSign = getNumberAttr(legModel, "KneePitchSign", 1),
		yawOffset = math.rad(getNumberAttr(legModel, "YawOffsetDegrees", 0)),
		hipPitchOffset = math.rad(getNumberAttr(legModel, "HipPitchOffsetDegrees", 0)),
		kneePitchOffset = math.rad(getNumberAttr(legModel, "KneePitchOffsetDegrees", 0)),
	}
end

local legs = {}
local legModels = legsFolder:GetChildren()
table.sort(legModels, function(a, b)
	return a.Name < b.Name
end)

for index, legModel in ipairs(legModels) do
	local leg = buildLeg(legModel, index, #legModels)
	if leg then
		table.insert(legs, leg)
	end
end

if #legs == 0 then
	error("No valid legs found in Legs folder.")
end

local function getDesiredFootWorld(leg, moveDir, stride)
	local base = body.CFrame:PointToWorldSpace(leg.defaultFootLocal)
	local desired = base
	if stride > 0.001 and moveDir.Magnitude > 0.001 then
		desired = desired + moveDir.Unit * stride
	end

	local rayOrigin = desired + Vector3.new(0, config.RayHeight, 0)
	local rayDir = Vector3.new(0, -config.RayDistance, 0)
	local result = Workspace:Raycast(rayOrigin, rayDir, rayParams)
	if result then
		desired = result.Position + Vector3.new(0, config.FootLift, 0)
	end

	return desired
end

local function solveIK(leg, targetWorld)
	local hipWorld = leg.hipMotor.Part0.CFrame * leg.hipMotor.C0
	local localTarget = hipWorld:PointToObjectSpace(targetWorld)

	local rawYaw = math.atan2(localTarget.X, localTarget.Z)
	local rotated = CFrame.Angles(0, -rawYaw, 0):VectorToWorldSpace(localTarget)
	local planarZ = rotated.Z * leg.forwardSign
	local planarY = rotated.Y

	local dist = math.sqrt(planarY * planarY + planarZ * planarZ)
	local maxReach = leg.upperLen + leg.lowerLen - 0.001
	local minReach = math.abs(leg.upperLen - leg.lowerLen) + 0.001
	dist = math.clamp(dist, minReach, maxReach)

	local targetAngle = math.atan2(planarZ, -planarY)
	local alpha = math.acos(math.clamp(
		(leg.upperLen * leg.upperLen + dist * dist - leg.lowerLen * leg.lowerLen) / (2 * leg.upperLen * dist),
		-1,
		1
	))
	local beta = math.acos(math.clamp(
		(leg.upperLen * leg.upperLen + leg.lowerLen * leg.lowerLen - dist * dist) / (2 * leg.upperLen * leg.lowerLen),
		-1,
		1
	))

	local hipPitch = (targetAngle - alpha) * leg.hipPitchSign + leg.hipPitchOffset
	local kneePitch = (math.pi - beta) * leg.kneePitchSign + leg.kneePitchOffset

	leg.hipMotor.Transform = leg.hipBaseTransform * CFrame.Angles(0, rawYaw * leg.yawSign + leg.yawOffset, 0)
	leg.thighMotor.Transform = leg.thighBaseTransform * CFrame.Angles(hipPitch, 0, 0)
	leg.calfMotor.Transform = leg.calfBaseTransform * CFrame.Angles(-kneePitch, 0, 0)
end

local function updateMovement()
	local throttle = seat.Throttle
	local steer = seat.Steer

	local velocity = body.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)

	local desiredVelocity = body.CFrame.LookVector * (config.MaxSpeed * throttle)
	local velocityDelta = desiredVelocity - horizontalVelocity

	local accel = velocityDelta * config.Acceleration
	moveForce.Force = Vector3.new(accel.X, 0, accel.Z) * body.AssemblyMass

	turnTorque.AngularVelocity = Vector3.new(0, steer * config.TurnSpeed, 0)

	if config.KeepUpright then
		local _, yaw, _ = body.CFrame:ToOrientation()
		uprightAlign.CFrame = CFrame.fromOrientation(0, yaw, 0)
		uprightAlign.Enabled = true
	else
		uprightAlign.Enabled = false
	end
end

local function shouldStep(leg, desiredWorld, now)
	local dist = (desiredWorld - leg.currentFootWorld).Magnitude
	if dist < config.StepTrigger then
		return false
	end

	local phase = (now * config.GaitSpeed + leg.phaseOffset) % 1
	return phase < config.StepWindow
end

local function updateLegs(now)
	local velocity = body.AssemblyLinearVelocity
	local moveDir = Vector3.new(velocity.X, 0, velocity.Z)
	local strideScale = math.clamp(moveDir.Magnitude / math.max(config.MaxSpeed, 1), 0, 1)

	if moveDir.Magnitude < 0.01 then
		moveDir = body.CFrame.LookVector * seat.Throttle
	end

	local stride = config.StepLength * strideScale

	for _, leg in ipairs(legs) do
		local desired = getDesiredFootWorld(leg, moveDir, stride)

		if not leg.isStepping and shouldStep(leg, desired, now) then
			leg.isStepping = true
			leg.stepStart = now
			leg.stepFrom = leg.currentFootWorld
			leg.stepTo = desired
		end

		if leg.isStepping then
			local t = (now - leg.stepStart) / config.StepDuration
			if t >= 1 then
				leg.isStepping = false
				leg.currentFootWorld = leg.stepTo
			else
				local pos = leg.stepFrom:Lerp(leg.stepTo, t)
				local lift = math.sin(t * math.pi) * config.StepHeight
				leg.currentFootWorld = pos + Vector3.new(0, lift, 0)
			end
		end

		solveIK(leg, leg.currentFootWorld)
	end
end

local function resetTransforms()
	for _, leg in ipairs(legs) do
		leg.hipMotor.Transform = leg.hipBaseTransform
		leg.thighMotor.Transform = leg.thighBaseTransform
		leg.calfMotor.Transform = leg.calfBaseTransform
	end
end

resetTransforms()

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	updateMovement()
	updateLegs(now)
end)
