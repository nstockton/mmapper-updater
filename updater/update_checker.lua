require("mystdlib")
local getch = require("getch")
local json = require("dkjson")
local lfs = require("lfs")

local APP_NAME = "MMapper"
local SCRIPT_VERSION = "1.0"
local GITHUB_USER = "MUME"
local APPVEYOR_USER = "nschimme"
local REPO = "MMapper"
local RELEASE_INFO_FILE = "update_info.ignore"
local ZIP_FILE = "mmapper.zip"

local HELP_TEXT = [[
-h, --help:	Display this help.
-release, -dev:	 Specify whether the latest stable release from GitHub should be used, or the latest development build from AppVeyor (defaults to release).
-x, -x86, -x64:	Specify the architecture of the binaries to download (defaults to the system architecture or x86 if not found). -x will attempt to use the architecture reported by the system.
-MinGW, -VS:	Specify which binaries to download based on compiler (defaults to MinGW).
]]


local function machine_arch()
	-- returns 'x64' if the version of Windows is 64-bit, 'x86' otherwise.
	local arch = architecture()
	return arch and string.findpos(arch, "64") and "x64" or "x86"
end

local function get_last_info()
	-- Return the previously stored release information as a table.
	local release_data = {}
	if os.isFile(RELEASE_INFO_FILE) then
		local fileObj = io.open(RELEASE_INFO_FILE, "rb")
		release_data = json.decode(fileObj:read("*all"), 1, nil)
		fileObj:close()
	end
	return release_data
end

local function save_last_info(tbl)
	-- Encode the release information in tbl to JSon, and save it to a file.
	local ordered_keys = {}
	for k, v in pairs(tbl) do
		table.insert(ordered_keys, k)
	end
	table.sort(ordered_keys)
	local data = string.gsub(json.encode(tbl, {indent=true, level=0, keyorder=ordered_keys}), "\r?\n", "\r\n")
	local handle = io.open(RELEASE_INFO_FILE, "wb")
	handle:write(data)
	handle:close()
end

local function _get_latest_github(arch, compiler)
	local project_url = string.format("https://api.github.com/repos/%s/%s/releases/latest", GITHUB_USER, REPO)
	local command = string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - \"%s\"", project_url)
	local handle = io.popen(command)
	local result = handle:read("*all")
	local gh = json.decode(result, 1, nil)
	handle:close()
	local release_data = {}
	release_data.arch = arch or "x86"
	release_data.compiler = compiler or "mingw"
	release_data.status = "success"
	if gh then
		release_data.tag_name = gh.tag_name
		for i, asset in ipairs(gh.assets) do
			if string.match(string.lower(asset.name), "^mmapper[-].-[-]windows[-]" .. release_data.arch .. ".zip$") then
				release_data.download_url = asset.browser_download_url
				release_data.size = asset.size
				release_data.updated_at = asset.updated_at
			elseif string.match(string.lower(asset.name), "^mmapper[-].-[-]windows[-]" .. release_data.arch .. ".zip.sha256$") then
				release_data.sha256_url = asset.browser_download_url
			end
		end
	end
	release_data.tag_name = release_data.tag_name or ""
	release_data.download_url = release_data.download_url or ""
	release_data.size = release_data.size or 0
	release_data.updated_at = release_data.updated_at or ""
	release_data.sha256_url = release_data.sha256_url or ""
	release_data.provider = "github"
	return release_data
end

local function _get_latest_appveyor(arch, compiler)
	local project_url = string.format("https://ci.appveyor.com/api/projects/%s/%s", APPVEYOR_USER, REPO)
	local command = string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - \"%s\"", project_url)
	local handle = io.popen(command)
	local result = handle:read("*all")
	local av = json.decode(result, 1, nil)
	handle:close()
	local release_data = {}
	release_data.arch = arch or "x86"
	release_data.compiler = compiler or "mingw"
	release_data.status = av and av.build.status or nil
	if release_data.status == "success" then
		release_data.tag_name = string.match(av.build.version, "^[vV](.+)[-][^-]+$")
		release_data.updated_at = av.build.updated
		for i, job in ipairs(av.build.jobs) do
			local job_arch = string.match(string.lower(job.name), "arch=(x%d%d)")
			local job_compiler = string.match(string.lower(job.name), "compiler=([^%s%d,]+)")
			if job.status == "success" and job_arch == release_data.arch and compiler == release_data.compiler then
				release_data.download_url = string.format("%s/artifacts/winbuild/mmapper-%s-Windows-%s.zip?branch=master&job=%s", project_url, release_data.tag_name, release_data.arch, url_quote(job.name))
				release_data.sha256_url = string.format("%s/artifacts/winbuild/mmapper-%s-Windows-%s.zip.sha256?branch=master&job=%s", project_url, release_data.tag_name, release_data.arch, url_quote(job.name))
			end
		end
	end
	release_data.tag_name = release_data.tag_name or ""
	release_data.download_url = release_data.download_url or ""
	release_data.size = nil
	release_data.updated_at = release_data.updated_at or ""
	release_data.sha256_url = release_data.sha256_url or ""
	release_data.provider = "appveyor"
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
	local hash
	printf("Downloading %s %s %s %s (%s) from %s.", APP_NAME, release.tag_name, release.arch, release.compiler == "mingw" and "MinGW" or release.compiler == "vs" and "Visual Studio" or release.compiler, release.updated_at, release.provider == "github" and "GitHub" or release.provider == "appveyor" and "AppVeyor" or string.capitalize(release.provider))
	if release.sha256_url ~= "" then
		local handle = io.popen(string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - \"%s\"", release.sha256_url))
		hash = string.lower(string.strip(handle:read("*all")))
		handle:close()
		if not string.endswith(hash, ".zip") then
			printf("Invalid checksum '%s'", hash)
			return false
		end
		hash = string.match(hash, "^%S+")
	end
	os.execute(string.format("curl.exe --silent --location --retry 999 --retry-max-time 0 --continue-at - --output %s \"%s\"", ZIP_FILE, release.download_url))
	local downloaded_size , error = os.fileSize(ZIP_FILE)
	-- release.size should be nil if the provider's API doesn't support retrieving file size.
	-- If the provider does support retrieving file size, but for some reason did not send it, release.size should be 0.
	if downloaded_size and downloaded_size > 0 and downloaded_size == release.size or not release.size then
		if release.sha256_url == "" and release.provider == "github" and release.tag_name == "v19.04.0" then
			save_last_info(release)
			printf("Warning: GitHub releases do not currently have checksum files to verify the download. This will be fixed in the next %s release. You can ignore this message for now.", APP_NAME)
			return true
		end
		printf("Verifying download.")
		if not hash then
			printf("Error: no checksum available. Aborting.")
		elseif sha256sum_file(ZIP_FILE) == hash then
			save_last_info(release)
			printf("OK.")
			return true
		else
			printf("Error: checksums do not match. Aborting.")
		end
	elseif error then
		printf(error)
	else
		printf("Error downloading release: Downloaded file size and reported size from provider API do not match.")
	end
	if os.isFile(ZIP_FILE) then
		os.remove(ZIP_FILE)
	end
	return false
end

function do_extract()
	local pwd = lfs.currentdir()
	printf("Extracting files.")
	os.execute(string.format("unzip.exe -qq \"%s\" -d \"tempmmapper\"", ZIP_FILE))
	if os.isFile(ZIP_FILE) then
		os.remove(ZIP_FILE)
	end
	if not lfs.chdir(pwd .. "\\tempmmapper") then
		return printf("Error: failed to change directory to '%s\\tempmmapper'", pwd)
	end
	local copy_from
	for item in lfs.dir(lfs.currentdir()) do
		if lfs.attributes(item, "mode") == "directory" and string.startswith(string.lower(item), "mmapper-") then
			copy_from = string.format("tempmmapper\\%s", item)
			break
		end
	end
	lfs.chdir(pwd)
	os.execute(string.format("xcopy \"%s\" \"..\\mmapper\" /E /V /I /Q /R /Y", copy_from))
	os.execute("rd /S /Q \"tempmmapper\"")
	printf("Done.")
end

local function called_by_script()
	return get_flags(true)["calledbyscript"] or false
end

local function needs_help()
	local flags = get_flags(true)
	return flags["help"] or flags["h"] or flags["?"] or false
end

local function get_latest_info(last_provider, last_arch, last_compiler)
	local bool2int = function (b) return b and 1 or 0 end
	local flags = get_flags(true)
	local use_github = flags["release"]
	local use_appveyor = flags["dev"] or flags["devel"] or flags["development"]
	local use_mingw = flags["mingw"]
	local use_vs = flags["vs"]
	local use_x86 = flags["x86"]
	local use_x64 = flags["x64"]
	local detect_arch = flags["x"]
	assert(not (use_github and use_appveyor), "Error: release and development are mutually exclusive.")
	assert(not (use_mingw and use_vs), "Error: MinGW and VS are mutually exclusive.")
	assert(bool2int(use_x86) + bool2int(use_x64) + bool2int(detect_arch) <= 1, "Error: x86 and x64 are mutually exclusive.")
	assert(use_github and not use_x64 or not use_github, "Error: x86 is the only supported architecture for GitHub releases.")
	assert(use_github and not use_vs or not use_github, "Error: MinGW is the only supported compiler for GitHub releases.")
	local provider = use_github and "github" or use_appveyor and "appveyor" or last_provider or "github"
	local arch = detect_arch and machine_arch() or use_x86 and "x86" or use_x64 and "x64" or last_arch or machine_arch() or "x86"
	local compiler = use_mingw and "mingw" or use_vs and "vs" or last_compiler or "mingw"
	if provider == "github" then
		-- Change this if / when more options for GitHub releases become available.
		return _get_latest_github("x86", "mingw")
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
end

-- Clean up previously left junk.
if os.isFile(ZIP_FILE) then
	os.remove(ZIP_FILE)
end
if os.isDir("tempmmapper") then
	os.execute("rd /S /Q \"tempmmapper\"")
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
