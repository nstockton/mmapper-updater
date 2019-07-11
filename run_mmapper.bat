@echo off

cls

rem Change the current working directory to the location of this batch script.
pushd "%~dp0"

cd updater
luajit.exe update_checker.lua /CalledByScript
cd ..

if exist "mmapper\bin" (
	cd mmapper\bin
	start mmapper.exe
) else (
	echo Error: failed to start because MMapper was not found.
	pause
)

rem Reset the working directory to it's previous value, before this batch script was run.
popd
