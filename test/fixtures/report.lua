-- ==================================================================== report --
realPrint(('%d checks, %d failures'):format(checks, #failures))
for _, f in ipairs(failures) do realPrint('  FAIL ' .. f) end
if #failures > 0 then error('harness failed') end
