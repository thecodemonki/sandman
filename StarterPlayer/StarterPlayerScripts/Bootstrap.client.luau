-- Client entry point, mirrors ServerScriptService/Runtime/Bootstrap.server.luau: calls
-- Init() on every controller that has one. Add a new controller = one line here.

local Controllers = script.Parent.Controllers

local CONTROLLER_MODULES = {
	Controllers.UIController,
	Controllers.FarmController,
	Controllers.BuildController,
}

for _, controllerModule in CONTROLLER_MODULES do
	local ok, controllerOrErr = pcall(require, controllerModule)
	if not ok then
		warn(("Bootstrap.client: failed to require %s: %s"):format(controllerModule.Name, tostring(controllerOrErr)))
		continue
	end

	local controller = controllerOrErr
	if type(controller.Init) == "function" then
		local initOk, initErr = pcall(controller.Init)
		if not initOk then
			warn(("Bootstrap.client: %s.Init() failed: %s"):format(controllerModule.Name, tostring(initErr)))
		end
	end
end
