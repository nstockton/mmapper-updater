@echo off

rem Change the current working directory to the location of this batch script.
pushd "%~dp0"

cd updater
rem Check for a new version of the update script before trying to update MMapper.
luajit.exe update_checker.lua /CalledByScript /update
rem now check for updates to MMapper.
luajit.exe update_checker.lua %*
cd ..

rem Reset the working directory to it's previous value, before this batch script was run.
popd
