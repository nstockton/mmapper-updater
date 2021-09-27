require("mystdlib")
local base64 = require("ee5_base64")
local getch = require("getch")
local json = require("dkjson")
local lfs = require("lfs")


local APP_NAME = "MMapper"
local SCRIPT_VERSION = "1.1"
local GITHUB_USER = "MUME"
local APPVEYOR_USER = "nschimme"
local REPO = "MMapper"
local RELEASE_INFO_FILE = "update_info.ignore"
local DOWNLOAD_DESTINATION = "mmapper_installer.exe"
local MAP_DESTINATION = "arda.mm2"
local TEMP_DIR = "tempmmapper"

local HELP_TEXT = [[
-h, --help:	Display this help.
-release, -dev:	 Specify whether the latest stable release from GitHub should be used, or the latest development build from AppVeyor (defaults to release).
-MinGW, -VS:	Specify which binaries to download based on compiler (defaults to MinGW).
]]


local function get_last_info()
	-- Return the previously stored release information as a table.
	if os.isFile(RELEASE_INFO_FILE) then
		local handle = assert(io.open(RELEASE_INFO_FILE, "rb"))
		local release_data, pos, err = json.decode(handle:read("*all"), 1, nil)
		handle:close()
		return assert(release_data, err)
	else
		return {}
	end
end


local function save_last_info(tbl)
	-- Encode the release information in tbl to JSon, and save it to a file.
	local ordered_keys = {}
	for k, v in pairs(tbl) do
		table.insert(ordered_keys, k)
	end
	table.sort(ordered_keys)
	local data = string.gsub(json.encode(tbl, {indent=true, level=0, keyorder=ordered_keys}), "\r?\n", "\r\n")
	local handle = assert(io.open(RELEASE_INFO_FILE, "wb"))
	handle:write(data)
	handle:close()
end


local function _get_latest_github(arch, compiler)
	local project_url = string.format("https://api.github.com/repos/%s/%s/releases/latest", GITHUB_USER, REPO)
	local command = string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - \"%s\"", project_url)
	local handle = assert(io.popen(command))
	local gh, pos, err = json.decode(handle:read("*all"), 1, nil)
	handle:close()
	assert(gh, err)
	local release_data = {}
	release_data.provider = "github"
	release_data.status = "success"
	release_data.arch = arch or "x64"
	release_data.compiler = compiler or "mingw"
	release_data.tag_name = assert(gh.tag_name, "Error: 'tag_name' not in retrieved data.")
	assert(gh.assets, "Error: 'assets' not in retrieved data.")
	for i, asset in ipairs(gh.assets) do
		assert(asset.name, "Error: 'name' not in 'asset'.")
		if string.startswith(asset.name, "mmapper-") and string.endswith(asset.name, "-Windows-" .. release_data.arch .. ".exe") then
			release_data.download_url = assert(asset.browser_download_url, "Error: 'browser_download_url' for installer not in 'asset'.")
			release_data.size = assert(asset.size, "Error: 'size' for installer not in 'asset'.")
			release_data.updated_at = assert(asset.updated_at, "Error: 'updated_at' for installer not in 'asset'.")
		elseif string.startswith(asset.name, "mmapper-") and string.endswith(asset.name, "-Windows-" .. release_data.arch .. ".exe.sha256") then
			release_data.sha256_url = assert(asset.browser_download_url, "Error: 'browser_download_url' for SHA256 not in 'asset'.")
		elseif asset.name == "arda.mm2" then
			release_data.map_download_url = assert(asset.browser_download_url, "Error: 'browser_download_url' for map not in 'asset'.")
			release_data.map_size = assert(asset.size, "Error: 'size' for map not in 'asset'.")
			release_data.map_updated_at = assert(asset.updated_at, "Error: 'updated_at' for map not in 'asset'.")
		end
	end
	return release_data
end


local function _get_latest_appveyor(arch, compiler)
	local project_url = string.format("https://ci.appveyor.com/api/projects/%s/%s", APPVEYOR_USER, REPO)
	local command = string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - \"%s\"", project_url)
	local handle = assert(io.popen(command))
	local av, pos, err = json.decode(handle:read("*all"), 1, nil)
	handle:close()
	assert(av, err)
	local release_data = {}
	release_data.provider = "appveyor"
	release_data.size = nil
	release_data.arch = arch or "x64"
	release_data.compiler = compiler or "mingw"
	assert(av.build, "Error: 'build' not in retrieved data.")
	release_data.status = assert(av.build.status, "Error: 'status' not in 'build'.")
	if release_data.status == "success" then
		assert(av.build.version, "Error: 'version' not in 'build'.")
		if string.findpos(av.build.version, "-0-g") then
			release_data.tag_name = string.match(av.build.version, "^[vV]([^-]+)")
		else
			release_data.tag_name = string.match(av.build.version, "^[vV](.+)[-][^-]+$")
		end
		release_data.updated_at = assert(av.build.updated, "Error: 'updated' not in 'build'.")
		assert(av.build.jobs, "Error: 'jobs' not in 'build'.")
		for i, job in ipairs(av.build.jobs) do
			assert(job.name, "Error: 'name' not in job.")
			local job_arch = string.match(string.lower(job.name), "arch=(x%d%d)")
			local job_compiler = string.match(string.lower(job.name), "compiler=([^%s%d,]+)")
			assert(job.status, "Error: 'status' not in job.")
			if job.status == "success" and job_arch == release_data.arch and job_compiler == release_data.compiler then
				release_data.download_url = string.format("%s/artifacts/mmapper-%s-Windows-%s.exe?branch=master&pr=false&job=%s", project_url, release_data.tag_name, release_data.arch, url_quote(job.name))
				release_data.sha256_url = string.format("%s/artifacts/mmapper-%s-Windows-%s.exe.sha256?branch=master&pr=false&job=%s", project_url, release_data.tag_name, release_data.arch, url_quote(job.name))
			end
		end
	end
	return release_data
end


local function prompt_for_update()
	io.write("Update now? (Y to update, N to skip this release in future, Q to exit and do nothing) ")
	local response = string.lower(string.strip(getch.getch()))
	io.write("\n")
	if response == "" then
		return prompt_for_update()
	elseif response == "y" then
		return "y"
	elseif response == "n" then
		return "n"
	elseif response == "q" then
		return "q"
	else
		printf("Invalid response. Please try again.")
		return prompt_for_update()
	end
end


local function do_download(release)
	printf("Downloading %s %s %s %s (%s) from %s.", APP_NAME, release.tag_name, release.arch, release.compiler == "mingw" and "MinGW" or release.compiler == "vs" and "Visual Studio" or release.compiler, release.updated_at, release.provider == "github" and "GitHub" or release.provider == "appveyor" and "AppVeyor" or string.capitalize(release.provider))
	local handle = assert(io.popen(string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - \"%s\"", release.sha256_url)))
	local result = string.lower(string.strip(handle:read("*all")))
	handle:close()
	local hash = assert(string.match(result, "^([0-9a-f]+).+%.exe$"), string.format("Invalid checksum '%s'", result))
	os.execute(string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - --output %s \"%s\"", DOWNLOAD_DESTINATION, release.download_url))
	local downloaded_size = assert(os.fileSize(DOWNLOAD_DESTINATION))
	if release.map_download_url then
		printf("Downloading map file from %s.", release.provider == "github" and "GitHub" or release.provider == "appveyor" and "AppVeyor" or string.capitalize(release.provider))
		os.execute(string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - --output %s \"%s\"", MAP_DESTINATION, release.map_download_url))
		assert(os.isFile(MAP_DESTINATION), "Error downloading map: downloaded file not found.")
		local map_downloaded_size = assert(os.fileSize(MAP_DESTINATION))
		assert(map_downloaded_size > 0 and map_downloaded_size == release.map_size, "Error downloading map: Downloaded file size and reported size from provider API do not match.")
	end
	-- release.size should be nil if the provider's API doesn't support retrieving file size.
	-- If the provider does support retrieving file size, but for some reason did not send it, release.size should be 0.
	assert(not release.size or downloaded_size and downloaded_size > 0 and downloaded_size == release.size, "Error downloading release: Downloaded file size and reported size from provider API do not match.")
	printf("Verifying download.")
	if sha256sum_file(DOWNLOAD_DESTINATION) == hash then
		save_last_info(release)
		printf("OK.")
		return true
	else
		printf("Error: checksums do not match. Aborting.")
		if os.isFile(DOWNLOAD_DESTINATION) then
			os.remove(DOWNLOAD_DESTINATION)
		end
		return false
	end
end


local function do_extract()
	local pwd = lfs.currentdir()
	printf("Extracting files.")
	os.execute(string.format("7z.exe x \"%s\" -o\"%s\" \"bin\" > nul", DOWNLOAD_DESTINATION, TEMP_DIR))
	assert(os.isDir(TEMP_DIR), "Error extracting files.")
	if os.isFile(MAP_DESTINATION) then
		os.rename(string.format("./%s", MAP_DESTINATION), string.format("./%s/%s", TEMP_DIR, MAP_DESTINATION))
	end
	if os.isFile(DOWNLOAD_DESTINATION) then
		os.remove(DOWNLOAD_DESTINATION)
	end
	os.execute(string.format("xcopy \"%s\" \"..\\mmapper\" /E /V /I /Q /R /Y", TEMP_DIR))
	os.execute(string.format("rd /S /Q \"%s\"", TEMP_DIR))
	printf("Done.")
end


local function called_by_script()
	return get_flags(true)["calledbyscript"] or false
end


local function needs_help()
	local flags = get_flags(true)
	return flags["help"] or flags["h"] or flags["?"] or false
end


local function needs_script_update()
	local flags = get_flags(true)
	return flags["update"] or flags["u"] or false
end


local function script_download_7z()
	if os.isFile("7z.exe") and os.isFile("7z.dll") then
		return
	end
	local project_url = function (name) return string.format("https://api.github.com/repos/nstockton/mmapper-updater/contents/updater/%s?ref=master", name) end
	local commands = {}
	table.insert(commands, string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - \"%s\"", project_url("7z.exe")))
	table.insert(commands, string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - \"%s\"", project_url("7z.dll")))
	for i, command in ipairs(commands) do
		local handle = assert(io.popen(command))
		local gh, pos, err = json.decode(handle:read("*all"), 1, nil)
		handle:close()
		assert(gh, err)
		-- GitHub might return an error message if the path was invalid, ETC.
		assert(gh.encoding and gh.content and gh.size, gh.message or "Error: unknown data returned.")
		assert(gh.encoding == "base64", string.format("Error: unknown encoding '%s', should be 'base64'.", gh.encoding))
		local content = base64.decode(gh.content)
		assert(gh.size > 0, "Error: reported size by GitHub is 0.")
		assert(string.len(content) == gh.size, "Error: size of retrieved content and reported size by GitHub do not match.")
		local name = assert(gh.name, "Error: cannot retrieve file name when downloading 7zip.")
		local handle = assert(io.open(name, "wb"))
		handle:write(content)
		handle:close()
	end
	printf("7zip has been successfully downloaded.")
end


local function script_update()
	script_download_7z()
	local project_url = "https://api.github.com/repos/nstockton/mmapper-updater/contents/updater/update_checker.lua?ref=master"
	local script_path = assert(get_script_path(), "Error: Unable to retrieve path of the updater script.")
	assert(os.isFile(script_path), string.format("Error: '%s' is not a file.", script_path))
	local script_size = assert(os.fileSize(script_path))
	local handle = assert(io.open(script_path, "rb"))
	local script_data = assert(handle:read("*all"), string.format("Error: Unable to read data from '%s'.", script_path))
	handle:close()
	local command = string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - \"%s\"", project_url)
	local handle = assert(io.popen(command))
	local gh, pos, err = json.decode(handle:read("*all"), 1, nil)
	handle:close()
	assert(gh, err)
	-- GitHub might return an error message if the path was invalid, ETC.
	assert(gh.encoding and gh.content and gh.size, gh.message or "Error: unknown data returned.")
	assert(gh.encoding == "base64", string.format("Error: unknown encoding '%s', should be 'base64'.", gh.encoding))
	local content = base64.decode(gh.content)
	assert(gh.size > 0, "Error: reported size by GitHub is 0.")
	assert(string.len(content) == gh.size, "Error: size of retrieved content and reported size by GitHub do not match.")
	if script_data ~= content then
		local handle = assert(io.open(script_path, "wb"))
		handle:write(content)
		handle:close()
		printf("The update script has been successfully updated.")
	elseif not called_by_script() then
		printf("The update script is up to date.")
	end
end


local function get_latest_info(last_provider, last_arch, last_compiler)
	local flags = get_flags(true)
	local use_github = flags["release"]
	local use_appveyor = flags["dev"] or flags["devel"] or flags["development"]
	local use_mingw = flags["mingw"]
	local use_vs = flags["vs"]
	assert(not (use_github and use_appveyor), "Error: release and development are mutually exclusive.")
	assert(not (use_mingw and use_vs), "Error: MinGW and VS are mutually exclusive.")
	assert(use_github and not use_vs or not use_github, "Error: MinGW is the only supported compiler for GitHub releases.")
	local provider = use_github and "github" or use_appveyor and "appveyor" or last_provider or "github"
	local arch = "x64"
	local compiler = use_mingw and "mingw" or use_vs and "vs" or last_compiler or "mingw"
	if provider == "github" then
		-- Change this if / when more options for GitHub releases become available.
		return _get_latest_github(arch, "mingw")
	elseif provider == "appveyor" then
		return _get_latest_appveyor(arch, compiler)
	else
		assert(nil, string.format("Invalid provider: '%s'.", provider))
	end
end


local last = get_last_info()


if needs_help() then
	printf("%s Updater V%s.", APP_NAME, SCRIPT_VERSION)
	printf(HELP_TEXT)
	os.exit(0)
elseif needs_script_update() then
	script_update()
	os.exit(0)
end


-- Clean up previously left junk.
if os.isFile(DOWNLOAD_DESTINATION) then
	os.remove(DOWNLOAD_DESTINATION)
end
if os.isDir(TEMP_DIR) then
	os.execute(string.format("rd /S /Q \"%s\"", TEMP_DIR))
end


local latest = get_latest_info(last.provider, last.arch, last.compiler)


if os.isDir("..\\mmapper") and not called_by_script() then
	printf("Checking for updates to %s.", APP_NAME)
end
if latest.status ~= "success" then
	printf("Error: unable to update at this time. Please try again in a few minutes.")
	printf("Build status returned by the server was (%s).", latest.status or "unknown")
	os.exit(1)
elseif not os.isDir("..\\mmapper") then
	printf("%s not found. This is normal for new installations.", APP_NAME)
	if do_download(latest) then
		do_extract()
	end
elseif last.skipped_release and last.skipped_release == latest.tag_name .. latest.updated_at .. latest.arch .. latest.compiler then
	printf("The update to %s (%s %s %s) dated %s from %s was previously skipped.", APP_NAME, latest.tag_name, latest.arch, latest.compiler == "mingw" and "MinGW" or latest.compiler == "vs" and "Visual Studio" or latest.compiler, latest.updated_at, latest.provider == "github" and "GitHub" or latest.provider == "appveyor" and "AppVeyor" or string.capitalize(latest.provider))
	if called_by_script() then
		os.exit(0)
	end
elseif last.tag_name and last.updated_at and last.arch and last.compiler and last.tag_name .. last.updated_at .. last.arch .. last.compiler == latest.tag_name .. latest.updated_at .. latest.arch .. latest.compiler then
	printf("You are currently running the latest %s (%s %s %s) dated %s from %s.", APP_NAME, latest.tag_name, latest.arch, latest.compiler == "mingw" and "MinGW" or latest.compiler == "vs" and "Visual Studio" or latest.compiler, latest.updated_at, latest.provider == "github" and "GitHub" or latest.provider == "appveyor" and "AppVeyor" or string.capitalize(latest.provider))
	if called_by_script() then
		os.exit(0)
	end
else
	printf("A new version of %s (%s %s %s) dated %s from %s was found.", APP_NAME, latest.tag_name, latest.arch, latest.compiler == "mingw" and "MinGW" or latest.compiler == "vs" and "Visual Studio" or latest.compiler, latest.updated_at, latest.provider == "github" and "GitHub" or latest.provider == "appveyor" and "AppVeyor" or string.capitalize(latest.provider))
	local user_choice = prompt_for_update()
	if user_choice == "y" then
		if do_download(latest) then
			do_extract()
		end
	elseif user_choice == "n" then
		printf("You will no longer be prompted to download this version of %s.", APP_NAME)
		last.skipped_release = latest.tag_name .. latest.updated_at .. latest.arch .. latest.compiler
		save_last_info(last)
	end
end


pause()
os.exit(0)
