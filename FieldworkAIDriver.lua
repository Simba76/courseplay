--[[
This file is part of Courseplay (https://github.com/Courseplay/courseplay)
Copyright (C) 2018 Peter Vajko

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]

--[[
Fieldwork AI Driver

Can follow a fieldworking course, perform turn maneuvers, turn on/off and raise/lower implements,
add adjustment course if needed.
]]

---@class FieldworkAIDriver : AIDriver
FieldworkAIDriver = CpObject(AIDriver)

FieldworkAIDriver.myStates = {
	FIELDWORK = {},
	UNLOAD_OR_REFILL = {},
	HELD = {},
	WAITING_FOR_LOWER = {},
	WAITING_FOR_RAISE = {}
}

-- Our class implementation does not call the constructor of base classes
-- through multiple level of inheritances therefore we must explicitly call
-- the base class ctr.
function FieldworkAIDriver:init(vehicle)
	AIDriver.init(self, vehicle)
	self:initStates(FieldworkAIDriver.myStates)
	-- waiting for tools to turn on, unfold and lower
	self.waitingForTools = true
	self.speed = 0
	self.debugChannel = 14
end

--- Start the oourse and turn on all implements when needed
function FieldworkAIDriver:start(ix)
	AIDriver.start(self, ix)
	self:setUpCourses()
	-- stop at the last waypoint by default
	self.vehicle.cp.stopAtEnd = true
	self.waitingForTools = true
	if not self.alignmentCourse then
		-- if there's no alignment course, start work immediately
		-- TODO: should probably better start it when the initialized waypoint (ix) is reached
		-- as we may start the vehicle outside of the field?
		self:changeToFieldwork()
	else
		self.state = self.states.ALIGNMENT
	end

end

function FieldworkAIDriver:stop(msgReference)
	self:stopWork()
	AIDriver.stop(self, msgReference)
end

function FieldworkAIDriver:drive(dt)
	if self.state == self.states.FIELDWORK then
		self:driveFieldwork()
	elseif self.state == self.states.UNLOAD_OR_REFILL then
		-- just drive normally
		self.speed = self.vehicle.cp.speeds.street
	elseif self.state == self.states.ALIGNMENT then
		-- use the courseplay speed limit for fields
		self.speed = self.vehicle.cp.speeds.field
	end

	AIDriver.drive(self, dt)
end

function FieldworkAIDriver:changeToFieldwork()
	self:debug('change to fieldwork')
	self.state = self.states.FIELDWORK
	self.fieldWorkState = self.states.WAITING_FOR_LOWER
	self:startWork()
end

function FieldworkAIDriver:changeToUnloadOrRefill()
	self:stopWork()
	self.state = self.states.UNLOAD_OR_REFILL
	self.course = self.unloadRefillCourse
	self.ppc:setCourse(self.course)
	self:debug('changing to unload/refill course (%d waypoints)', #self.course.waypoints)
	self.ppc:initialize(1)
end

function FieldworkAIDriver:onEndAlignmentCourse()
	self:changeToFieldwork()
end

function FieldworkAIDriver:onEndCourse()
	self:stop('END_POINT')
end

function FieldworkAIDriver:getFieldSpeed()
	-- use the speed limit supplied by Giants for fieldwork
	local speedLimit = self.vehicle:getSpeedLimit() or math.huge
	return math.min(self.vehicle.cp.speeds.field, speedLimit)
end

function FieldworkAIDriver:getSpeed()
	local speed = self.speed or 10
	-- as long as other CP components mess with the cruise control we need to reset this, for example after
	-- a turn
	self.vehicle:setCruiseControlMaxSpeed(speed)
	return speed
end

--- Start the actual work. Lower and turn on implements
function FieldworkAIDriver:startWork()
	self:debug('Starting work: turn on and lower implements.')
	courseplay:lowerImplements(self.vehicle)
	self.vehicle:raiseAIEvent("onAIStart", "onAIImplementStart")
end

--- Stop working. Raise and stop implements
function FieldworkAIDriver:stopWork()
	self:debug('Ending work: turn off and raise implements.')
	courseplay:raiseImplements(self.vehicle)
	self.vehicle:raiseAIEvent("onAIEnd", "onAIImplementEnd")
end

--- Check all worktools to see if we are ready
function FieldworkAIDriver:areAllWorkToolsReady()
	if not self.vehicle.cp.workTools then return true end
	local allToolsReady = true
	for _, workTool in pairs(self.vehicle.cp.workTools) do
		allToolsReady = self:isWorktoolReady(workTool) and allToolsReady
	end
	return allToolsReady
end

--- Check if need to refill anything
function FieldworkAIDriver:allFillLevelsOk()
	if not self.vehicle.cp.workTools then return false end
	local allOk = true
	for _, workTool in pairs(self.vehicle.cp.workTools) do
		allOk = self:fillLevelsOk(workTool) and allOk
	end
	return allOk
end

--- Check fill levels in all tools and stop when one of them isn't
-- ok (empty or full, depending on the derived class)
function FieldworkAIDriver:fillLevelsOk(workTool)
	if workTool.getFillUnits then
		for index, fillUnit in pairs(workTool:getFillUnits()) do
			-- let's see if we can get by this abstraction for all kinds of tools
			local ok = self:isLevelOk(workTool, index, fillUnit)
			if not ok then
				return false
			end
		end
	end
	-- all fill levels ok
	return true
end

--- Check if worktool is ready for work
function FieldworkAIDriver:isWorktoolReady(workTool)
	local _, _, isUnfolded = courseplay:isFolding(workTool)

	-- TODO: move these to a generic helper?
	local isTurnedOn = true
	if workTool.spec_turnOnVehicle then
		isTurnedOn = workTool:getAIRequiresTurnOn() and workTool:getIsTurnedOn()
	end

	local isLowered = courseplay:isLowered(workTool)
	courseplay.debugVehicle(12, workTool, 'islowered=%s isturnedon=%s unfolded=%s', isLowered, isTurnedOn, isUnfolded)
	return isLowered and isTurnedOn and isUnfolded
end

-- is the fill level ok to continue?
function FieldworkAIDriver:isLevelOk(workTool, index, fillUnit)
	-- implement specifics in the derived classes
	return true
end

-- Text for AIDriver.stop(msgReference) to display as the reason why we stopped
function FieldworkAIDriver:getFillLevelWarningText()
	return nil
end

--- Set up the main (fieldwork) course and the unload/refill course
-- Currently, the legacy CP code just dumps all loaded courses to vehicle.Waypoints so
-- now we have to figure out which of that is the actual fieldwork course and which is the
-- refill/unload part.
-- This should better be handled by the course management though and should be refactored.
function FieldworkAIDriver:setUpCourses()
	local nWaits = 0
	local endFieldCourseIx = 0
	for i, wp in ipairs(self.vehicle.Waypoints) do
		if wp.wait then
			nWaits = nWaits + 1
			-- the second wp with the wait attribute is the end of the field course (assuming
			-- the field course has been loaded first.
			if nWaits == 2 then
				endFieldCourseIx = i
				break
			end
		end
	end
	if #self.vehicle.Waypoints > endFieldCourseIx then
		self:debug('There seems to be an unload/refill course starting at waypoint %d', endFieldCourseIx + 1)
		self.mainCourse = Course(self.vehicle, self.vehicle.Waypoints, 1, endFieldCourseIx)
		self.unloadRefillCourse = Course(self.vehicle, self.vehicle.Waypoints, endFieldCourseIx + 1, #self.vehicle.Waypoints)
	else
		self:debug('There seems to be no unload/refill course')
		self.mainCourse = Course(self.vehicle, self.vehicle.Waypoints, 1, #self.vehicle.Waypoints)
	end
end