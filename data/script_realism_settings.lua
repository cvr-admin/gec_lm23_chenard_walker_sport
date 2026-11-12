-- Shared runtime settings for the CSP Lua realism ecosystem.
-- Keep this outside script_car_parameters.lua: it is common infrastructure,
-- while that file is reserved for values that differ from car to car.

local realismSettingsPath = ac.getFolder(ac.FolderID.ContentCars) .. "/" .. ac.getCarID(0) .. "/extension/realism_settings.ini"
local realismSettingsOK, realismSettings = pcall(ac.INIConfig.load, realismSettingsPath)
local onlineRealismSettings = nil
local onlineRealismSettingsActive = false
local onlineRealismSection = 'CVR_REALISM'
local realismSettingSections = {
    PIT_AND_ROADSIDE_REPAIRS = 'SERVICES',
    RESCUE_PUSH_INTERACTION = 'SERVICES',
    OVERHEAD_MESSAGES = 'FEEDBACK',
    VISUAL_EFFECTS = 'FEEDBACK',
    PSG_AUDIO = 'FEEDBACK',
    DEBUG_LOGGING = 'DEVELOPMENT',
}

local function updateOnlineRealismSettings(config)
    onlineRealismSettings = config
    onlineRealismSettingsActive = config ~= nil and config:get(onlineRealismSection, 'OVERRIDE_LOCAL', 0) == 1

    -- Usually the extra options are already available while this file is
    -- loading. This callback also covers servers which send them afterwards.
    if realismSettingsChanged then
        realismSettingsChanged()
    end
end

local onlineSettingsOK, initialOnlineSettings = pcall(ac.INIConfig.onlineExtras)
if onlineSettingsOK then
    updateOnlineRealismSettings(initialOnlineSettings)
end

ac.onOnlineWelcome(function(_, config)
    updateOnlineRealismSettings(config)
end)

local function getLocalRealismSetting(section, settingName, defaultValue)
    if not realismSettingsOK or not realismSettings then
        return defaultValue
    end
    return realismSettings:get(section, settingName, defaultValue)
end

-- Server CSP Extra Options are supplied in the online welcome config, rather
-- than read from a client file. With OVERRIDE_LOCAL=1, each supplied value in
-- [CVR_REALISM] wins; an omitted key safely falls back to the car's local INI.
local function getRealismSetting(section, settingName, defaultValue)
    local localValue = getLocalRealismSetting(section, settingName, defaultValue)
    if onlineRealismSettingsActive then
        return onlineRealismSettings:get(onlineRealismSection, settingName, localValue)
    end
    return localValue
end

function realismFeatureEnabled(featureName)
    local section = realismSettingSections[featureName] or 'REALISM'
    return getRealismSetting(section, featureName, 1) == 1
end

-- Race-control settings use the same safe default as realism feature groups:
-- preserve the historical enabled behaviour if the file is unavailable.
function raceControlEnabled(settingName)
    return getRealismSetting('RACE_CONTROL', settingName, 1) == 1
end

-- League race-length control. It scales background random reliability rolls:
-- 1.0 keeps this car's tuned values, 2.0 doubles their likelihood and 0.5
-- halves it. Collision and driver-abuse consequences remain untouched, except
-- for the separately included air-cooled fan-belt stress accumulation.
function getRaceLengthFailureMultiplier()
    local multiplier = getRealismSetting('RACE_CONTROL', 'RACE_LENGTH', 1.0)
    if type(multiplier) ~= 'number' or multiplier <= 0 then
        return 1.0
    end
    return multiplier
end

-- Failure rates are denominators: a smaller value produces a more frequent
-- random hit. Keep the configured safety minimum after applying the multiplier.
function scaleFailureRateForRaceLength(rate, minimumValue)
    local minimum = minimumValue or 1
    return math.max(minimum, math.floor(rate / getRaceLengthFailureMultiplier() + 0.5))
end
