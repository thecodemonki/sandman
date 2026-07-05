-- Single entry point for server startup. Calls Init() on every service that has one,
-- in the order listed below. Adding a new service later is one line in SERVICE_MODULES —
-- no restructuring here.

local ServerScriptService = game:GetService("ServerScriptService")
local Services = ServerScriptService.Services

-- Dependency order matters here; later entries may assume earlier ones already ran Init().
local SERVICE_MODULES = {
	Services.BuildService,
	Services.FarmingService,
	Services.MonsterService,
	Services.DefenseService,
}

for _, serviceModule in SERVICE_MODULES do
	local ok, serviceOrErr = pcall(require, serviceModule)
	if not ok then
		warn(("Bootstrap: failed to require %s: %s"):format(serviceModule.Name, tostring(serviceOrErr)))
		continue
	end

	local service = serviceOrErr
	if type(service.Init) == "function" then
		local initOk, initErr = pcall(service.Init)
		if not initOk then
			warn(("Bootstrap: %s.Init() failed: %s"):format(serviceModule.Name, tostring(initErr)))
		end
	end
end
