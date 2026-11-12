-- Optional, read-only handling telemetry. No controller inputs or physics setters.
-- Keep TYPE_C_HANDLING as the log prefix for existing analysis compatibility;
-- the META record identifies the actual car, so this module can be reused.
local handlingDiagnostics = {}
local sampleIntervalSeconds = 0.2
local maximumSampleCount = 4500
local sampleTimerSeconds = 0
local elapsedSeconds = 0
local sampleCount = 0
local runNumber = 1
local headerWritten = false
local previousSetupRecord = nil
local previousSessionIndex = nil
local setupReferences = nil

local setupNames = {
    'CAMBER_LF', 'CAMBER_RF', 'CAMBER_LR', 'CAMBER_RR',
    'TOE_OUT_LF', 'TOE_OUT_RF', 'TOE_OUT_LR', 'TOE_OUT_RR',
    'DAMP_BUMP_LF', 'DAMP_BUMP_RF', 'DAMP_BUMP_LR', 'DAMP_BUMP_RR',
    'DAMP_REBOUND_LF', 'DAMP_REBOUND_RF', 'DAMP_REBOUND_LR', 'DAMP_REBOUND_RR',
    'DIFF_POWER', 'DIFF_COAST', 'DIFF_PRELOAD', 'TYRES',
    'PRESSURE_LF', 'PRESSURE_RF', 'PRESSURE_LR', 'PRESSURE_RR'
}
local wheelNames = {'FL', 'FR', 'RL', 'RR'}
local wheelColumnNames = {
    'load_N', 'slip_angle_deg', 'slip_ratio', 'normalized_slip',
    'camber_render_deg', 'toe_in_render_deg', 'travel_m', 'damper_speed_mps',
    'longitudinal_force_N', 'lateral_force_N', 'core_C', 'dynamic_pressure_raw',
    'surface_grip', 'inflation', 'suspension_damage'
}

local function formatNumber(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return 'n/a'
    end
    return string.format('%.5f', number)
end

-- Only optional SDK field access is protected. Missing data is never a zero.
local function readOptionalNumber(object, fieldName)
    if not object then return nil end
    local success, value = pcall(function() return object[fieldName] end)
    if success then return tonumber(value) end
    return nil
end

local function appendNumber(record, value)
    record[#record + 1] = formatNumber(value)
end

function handlingDiagnostics.reset()
    -- Separate pit jumps/session changes without resetting the output budget.
    runNumber = runNumber + 1
    sampleTimerSeconds = 0
    previousSetupRecord = nil
end

local function writeHeader(carState)
    if not setupReferences then
        setupReferences = {}
        for _, setupName in ipairs(setupNames) do
            local success, reference = pcall(ac.getSetupValue, setupName)
            setupReferences[setupName] = success and reference or false
        end
    end
    ac.log('TYPE_C_HANDLING META car=' .. ac.getCarID(carState.index)
        .. ' track=' .. ac.getTrackID()
        .. ' rate_hz=5 limit_samples=4500; setup values are raw AC units;'
        .. ' camber/toe are render-state readings and can lag physics;'
        .. ' travel is raw suspension travel, not measured bump-stop clearance')
    local columns = {
        'time_s', 'run', 'session', 'lap', 'speed_kmh', 'rpm', 'gear_ac',
        'driver_throttle', 'delivered_throttle', 'brake', 'clutch', 'steer',
        'fuel_L', 'lateral_g', 'longitudinal_g', 'yaw_rate_radps',
        'lateral_velocity_mps', 'forward_velocity_mps', 'ambient_C',
        'road_C', 'road_grip', 'wind_kmh', 'in_pits', 'position_x_m', 'position_z_m'
    }
    for _, wheelName in ipairs(wheelNames) do
        for _, columnName in ipairs(wheelColumnNames) do
            columns[#columns + 1] = wheelName .. '_' .. columnName
        end
    end
    ac.log('TYPE_C_HANDLING CSV ' .. table.concat(columns, ','))
    headerWritten = true
end

local function writeSetupIfChanged()
    local values = {}
    for _, setupName in ipairs(setupNames) do
        local reference = setupReferences[setupName]
        values[#values + 1] = setupName .. '='
            .. formatNumber(reference and reference.value or nil)
    end
    local setupRecord = table.concat(values, ',')
    if setupRecord ~= previousSetupRecord then
        ac.log('TYPE_C_HANDLING SETUP run=' .. runNumber .. ',' .. setupRecord)
        previousSetupRecord = setupRecord
    end
end

function handlingDiagnostics.update(deltaTimeSeconds, physicsState, carState,
        simulationState, driverThrottle, enabled)
    if not enabled or sampleCount >= maximumSampleCount then return end
    if not deltaTimeSeconds or deltaTimeSeconds ~= deltaTimeSeconds
            or deltaTimeSeconds <= 0 or deltaTimeSeconds == math.huge then return end
    if simulationState.isPaused or simulationState.isInMainMenu
            or simulationState.isReplayActive then return end

    if previousSessionIndex ~= nil
            and previousSessionIndex ~= simulationState.currentSessionIndex then
        handlingDiagnostics.reset()
    end
    previousSessionIndex = simulationState.currentSessionIndex
    elapsedSeconds = elapsedSeconds + deltaTimeSeconds
    sampleTimerSeconds = sampleTimerSeconds + deltaTimeSeconds
    if sampleTimerSeconds < sampleIntervalSeconds then return end
    -- Do not invent duplicate historical samples after a stall/large timestep.
    sampleTimerSeconds = sampleTimerSeconds % sampleIntervalSeconds
    if not headerWritten then writeHeader(carState) end
    writeSetupIfChanged()

    local record = {}
    appendNumber(record, elapsedSeconds)
    appendNumber(record, runNumber)
    appendNumber(record, simulationState.currentSessionIndex)
    appendNumber(record, carState.lapCount)
    appendNumber(record, physicsState.speedKmh)
    appendNumber(record, physicsState.rpm)
    appendNumber(record, physicsState.gear)
    appendNumber(record, driverThrottle)
    appendNumber(record, physicsState.gas)
    appendNumber(record, physicsState.brake)
    appendNumber(record, physicsState.clutch)
    appendNumber(record, physicsState.steer)
    appendNumber(record, carState.fuel)
    appendNumber(record, physicsState.gForces.x)
    appendNumber(record, physicsState.gForces.z)
    appendNumber(record, physicsState.localAngularVelocity.y)
    appendNumber(record, physicsState.localVelocity.x)
    appendNumber(record, physicsState.localVelocity.z)
    appendNumber(record, physicsState.ambientTemperature)
    appendNumber(record, simulationState.roadTemperature)
    appendNumber(record, simulationState.roadGrip)
    appendNumber(record, simulationState.windSpeedKmh)
    appendNumber(record, carState.isInPit and 1 or 0)
    appendNumber(record, physicsState.position.x)
    appendNumber(record, physicsState.position.z)

    for wheelIndex = 0, 3 do
        local physicsWheel = physicsState.wheels[wheelIndex]
        local renderWheel = carState.wheels and carState.wheels[wheelIndex]
        appendNumber(record, physicsWheel.load)
        -- CPHYS slip angle is radians; the render-state equivalent is degrees.
        appendNumber(record, physicsWheel.slipAngle and math.deg(physicsWheel.slipAngle))
        appendNumber(record, physicsWheel.slipRatio)
        appendNumber(record, physicsWheel.ndSlip)
        appendNumber(record, readOptionalNumber(renderWheel, 'camber'))
        appendNumber(record, readOptionalNumber(renderWheel, 'toeIn'))
        appendNumber(record, physicsWheel.suspensionTravel)
        appendNumber(record, physicsWheel.damperSpeed)
        appendNumber(record, physicsWheel.fx)
        appendNumber(record, physicsWheel.fy)
        appendNumber(record, physicsWheel.coreTemperature)
        appendNumber(record, physicsWheel.dynamicPressure)
        appendNumber(record, physicsWheel.surfaceGrip)
        appendNumber(record, physicsWheel.inflation)
        appendNumber(record, physicsWheel.suspensionDamage)
    end
    ac.log('TYPE_C_HANDLING CSV ' .. table.concat(record, ','))
    sampleCount = sampleCount + 1
    if sampleCount == maximumSampleCount then
        ac.log('TYPE_C_HANDLING END sample budget reached; reload car/script to record again')
    end
end

return handlingDiagnostics
