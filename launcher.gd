class_name Launcher
extends Control


signal launcher_helper_ready
signal launcher_ready
signal mod_ready_to_play

const CONFIG_PATH = "user://config.ini"
const GAME_MENU_SCENE = preload("res://game_menu.tscn")
const ICON_MUTE = preload("res://icons/mute.svg")
const ICON_VOLUME = preload("res://icons/volume.svg")

@onready var config = ConfigFile.new()
@onready var mod_branch: LineEdit = $Content/VBoxContainer2/LineEditModBranch
@onready var custom_launch_options: LineEdit = $Content/VBoxContainer2/LineEditCustomLaunchOptions
@onready var mute: Button = $Content/ButtonMute
@onready var background_video: VideoStreamPlayer = $Content/VideoStreamPlayerBackground
@onready var accept_dialog: AcceptDialog = $AcceptDialog
@onready var http_request_launcher_helper: HTTPRequest = $HTTPRequestLauncherHelper
@onready var http_request_launcher_version: HTTPRequest = $HTTPRequestLauncherVersion
@onready var http_request_launcher: HTTPRequest = $HTTPRequestLauncher
@onready var http_request_mod_version: HTTPRequest = $HTTPRequestModVersion
@onready var http_request_mod: HTTPRequest = $HTTPRequestMod
@onready var timer_download_progress_launcher: Timer = $TimerDownloadProgressLauncher
@onready var timer_download_progress_mod: Timer = $TimerDownloadProgressMod
@onready var progress_bar_download_mod: ProgressBar = $Content/VBoxContainer/ProgressBarDownloadMod
@onready var progress_bar_download_launcher: ProgressBar = $ProgressBarDownloadLauncher
@onready var button_play: Button = $Content/VBoxContainer/ButtonPlay
@onready var file_dialog_installation: FileDialog = $FileDialogInstallation
@onready var label_info: Label = $LabelInfo
@onready var content: Control = $Content
@onready var label_version: Label = $Content/LabelVersion

var game_menu: GameMenu
var geometry: PackedStringArray
var pid: int
var installation_path: String
var local_version_content: String
var mod_needs_install := false


func _notification(what) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if pid != 0:
			OS.kill(pid)
			prints("Killed", pid)


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	label_version.text = "v" + ProjectSettings.get_setting("application/config/version")
	if not OS.get_cmdline_args().has("-debug"):
		# Download launcher helper
		var launcher_helper := "https://github.com/gb2dev/HLA-NoVR-Launcher-Helper/releases/latest/download/HLA-NoVR-Launcher-Helper.exe"
		var error_helper = http_request_launcher_helper.request(launcher_helper)
		if error_helper != OK:
			accept_dialog.dialog_text = "An error (%s) occurred while creating the HTTP request." % error_helper
			accept_dialog.show()
			await check_for_helper()

		await launcher_helper_ready

	launcher_ready.connect(func():
		timer_download_progress_launcher.stop()
		setup_config()
		content.visible = true
		background_video.play()
	, CONNECT_ONE_SHOT)

	mod_ready_to_play.connect(func():
		# Launch Game
		custom_launch_options.text = custom_launch_options.text.replace("-fullscreen", "")
		OS.shell_open("steam://run/546560// -novr +vr_enable_fake_vr 1 -condebug +hlvr_main_menu_delay 999999 +hlvr_main_menu_delay_with_intro 999999 +hlvr_main_menu_delay_with_intro_and_saves 999999 " + custom_launch_options.text + " -window")
		game_menu = GAME_MENU_SCENE.instantiate()
		game_menu.launcher = self
		add_child(game_menu)
		game_menu.visible = true
		var thread = Thread.new()
		thread.start(_thread_helper)
		background_video.stop()
		content.visible = false
		label_info.text = "Please confirm the launch of the game on Steam.
		If you accidentally canceled it or encounter any problems,
		close the game and restart this launcher."
		label_info.visible = true
	, CONNECT_ONE_SHOT)

	if OS.get_cmdline_args().has("-debug"):
		launcher_ready.emit()
	else:
		# Request newest launcher version
		var newest_version := "https://api.github.com/repos/gb2dev/HLA-NoVR-Launcher/releases/latest"
		var error_launcher = http_request_launcher_version.request(newest_version)
		if error_launcher != OK:
			accept_dialog.dialog_text = "An error (%s) occurred while creating the HTTP request." % error_launcher
			accept_dialog.show()
			launcher_ready.emit()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if not geometry.is_empty():
		var screen_pos := DisplayServer.screen_get_position()
		game_menu.position = Vector2(geometry[0].to_int() + screen_pos.x, geometry[1].to_int() + screen_pos.y)
		game_menu.size = Vector2(geometry[2].to_int() + 1, geometry[3].to_int() + 1)


func _input(event: InputEvent) -> void:
	if not game_menu:
		return
	if event is InputEventKey and event.is_pressed() and game_menu.remapping_input:
		var input := OS.get_keycode_string(event.keycode)
		input = input.to_upper().replace(" ", "_")
		game_menu.input_entered.emit(input)
		OS.execute("HLA-NoVR-Launcher-Helper.exe", ["focusgame"], [])
		label_info.text = ""
	elif event is InputEventMouseButton and event.is_pressed() and game_menu.remapping_input:
		var button_index: int = event.button_index
		if button_index > 5:
			button_index -= 4
		elif button_index > 3:
			return
		var input := "MOUSE%s" % button_index
		game_menu.input_entered.emit(input)
		OS.execute("HLA-NoVR-Launcher-Helper.exe", ["focusgame"], [])
		label_info.text = ""


func _thread_helper() -> void:
	var exec := OS.execute_with_pipe("HLA-NoVR-Launcher-Helper.exe", [])
	if exec.is_empty():
		accept_dialog.set_deferred(&"dialog_text", "HLA-NoVR-Launcher-Helper is missing.")
		accept_dialog.show.call_deferred()
		return
	pid = exec["pid"]
	var file: FileAccess = exec["stdio"]
	geometry.resize(4)
	while true:
		var line := file.get_line()
		if not line.is_empty():
			var command = line.split(":")
			if command[0] == "geometry":
				for i in 4:
					geometry[i] = command[i+1]
			elif command[0] == "exit":
				get_tree().quit()
			else:
				print(command)


func _thread_install_mod() -> void:
	var reader := ZIPReader.new()
	var err := reader.open("user://novr.zip")
	if err != OK:
		accept_dialog.dialog_text = "An error (%s) occurred while opening the mod files archive." % err
		accept_dialog.show()
		return PackedByteArray()
	for path in reader.get_files():
		var bytes := reader.read_file(path)
		var target_path := installation_path + path.lstrip("HLA-NoVR-" + mod_branch.text)
		if target_path.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(target_path)
		else:
			var file := FileAccess.open(target_path, FileAccess.WRITE)
			file.store_buffer(bytes)
	reader.close()
	mod_ready_to_play.emit.call_deferred()


func check_for_helper() -> void:
	if FileAccess.file_exists("HLA-NoVR-Launcher-Helper.exe"):
		launcher_helper_ready.emit()
	else:
		await accept_dialog.visibility_changed
		get_tree().quit()


func setup_config() -> void:
	config.load(CONFIG_PATH)

	# Installation Path
	installation_path = config.get_value(
		"Launcher",
		"installation_path",
		"C:/Program Files (x86)/Steam/steamapps/common/Half-Life Alyx"
	)

	# Mod Branch
	mod_branch.text = config.get_value(
		"Launcher",
		"mod_branch",
		"main"
	)
	mod_branch.text_changed.connect(func(new_text: String):
		config.set_value(
			"Launcher",
			"mod_branch",
			new_text
		)
		config.save(CONFIG_PATH)
	)

	# Custom Launch Options
	var screen_size := DisplayServer.screen_get_size()
	custom_launch_options.text = config.get_value(
		"Launcher",
		"custom_launch_options",
		"-console -vconsole -w " + str(screen_size.x) + " -h " + str(screen_size.y)
	)
	custom_launch_options.text_changed.connect(func(new_text: String):
		config.set_value(
			"Launcher",
			"custom_launch_options",
			new_text
		)
		config.save(CONFIG_PATH)
	)

	# Mute
	mute.button_pressed = config.get_value(
		"Launcher",
		"mute",
		false
	)
	mute.pressed.emit()
	mute.pressed.connect(func():
		config.set_value(
			"Launcher",
			"mute",
			mute.button_pressed
		)
		config.save(CONFIG_PATH)
	)


func _on_button_play_pressed() -> void:
	if not verify_installation_path(installation_path):
		background_video.paused = true
		file_dialog_installation.show()
		background_video.paused = false
	if not verify_installation_path(installation_path):
		accept_dialog.dialog_text = "Invalid game installation."
		accept_dialog.show()
		return

	if OS.get_cmdline_args().has("-debug"):
		mod_ready_to_play.emit()
		return

	# Get local mod version
	var local_version := installation_path + "/game/hlvr/scripts/vscripts/version.lua"
	var file = FileAccess.open(local_version, FileAccess.READ)
	local_version_content = ""
	if file == null:
		mod_needs_install = true
	else:
		local_version_content = file.get_as_text()

	# Request newest mod version
	var newest_version := "https://raw.githubusercontent.com/gb2dev/HLA-NoVR/" + mod_branch.text + "/game/hlvr/scripts/vscripts/version.lua"
	var error = http_request_mod_version.request(newest_version)
	if error != OK:
		accept_dialog.dialog_text = "An error (%s) occurred while creating the HTTP request." % error
		accept_dialog.show()


func verify_installation_path(dir: String) -> bool:
	if FileAccess.file_exists(dir + "/game/hlvr/pak01_dir.vpk"):
		return true
	return false


func _on_button_quit_pressed() -> void:
	get_tree().quit()


func _on_button_mute_pressed() -> void:
	mute.icon = ICON_MUTE if mute.button_pressed else ICON_VOLUME
	background_video.volume = 0 if mute.button_pressed else 1


func _on_http_request_launcher_helper_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		accept_dialog.dialog_text = "An error (%s) occurred in the HTTP request." % result
		accept_dialog.show()
		await check_for_helper()
		return

	if body.size() < 100:
		accept_dialog.dialog_text = "Launcher helper file not found."
		accept_dialog.show()
		await check_for_helper()
		return

	var file := FileAccess.open("HLA-NoVR-Launcher-Helper.exe", FileAccess.WRITE)
	if not file:
		accept_dialog.dialog_text = "Launcher helper file could not be saved."
		accept_dialog.show()
		await check_for_helper()
		return
	file.store_buffer(body)

	launcher_helper_ready.emit()


func _on_http_request_launcher_version_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		accept_dialog.dialog_text = "An error (%s) occurred in the HTTP request." % result
		accept_dialog.show()
		launcher_ready.emit()
		return

	var newest_version_content := body.get_string_from_utf8()
	var newest_version_dict: Dictionary = str_to_var(newest_version_content)
	if newest_version_dict.has("tag_name"):
		var newest_version: String = newest_version_dict["tag_name"]
		var local_version: String = ProjectSettings.get_setting("application/config/version")
		if newest_version == local_version or newest_version.begins_with("3"):
			launcher_ready.emit()
		else:
			# Download launcher update
			var launcher := "https://github.com/gb2dev/HLA-NoVR-Launcher/releases/latest/download/HLA-NoVR-Launcher.exe"
			timer_download_progress_launcher.start()
			var error = http_request_launcher.request(launcher)
			if error != OK:
				accept_dialog.dialog_text = "An error (%s) occurred while creating the HTTP request." % error
				accept_dialog.show()
			launcher_ready.emit()
	else:
		accept_dialog.dialog_text = "Could not get latest launcher version." % result
		accept_dialog.show()
		launcher_ready.emit()


func _on_http_request_launcher_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		accept_dialog.dialog_text = "An error (%s) occurred in the HTTP request." % result
		accept_dialog.show()
		launcher_ready.emit()
		return

	if body.size() < 100:
		accept_dialog.dialog_text = "Launcher update file not found."
		accept_dialog.show()
		launcher_ready.emit()
		return

	var file := FileAccess.open("HLA-NoVR-Launcher.exe.update", FileAccess.WRITE)
	file.store_buffer(body)

	var pid = OS.create_process("HLA-NoVR-Launcher-Helper.exe", ["update"])
	get_tree().quit()


func _on_http_request_mod_version_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		accept_dialog.dialog_text = "An error (%s) occurred in the HTTP request." % result
		accept_dialog.show()
		if not mod_needs_install:
			mod_ready_to_play.emit()
		return

	var newest_version_content = body.get_string_from_utf8()

	# (Re)install mod if there is a version difference
	var install_mod: bool = local_version_content != newest_version_content
	button_play.disabled = true
	mod_branch.editable = false
	if install_mod:
			var mod := "https://github.com/gb2dev/HLA-NoVR/archive/refs/heads/" + mod_branch.text + ".zip"
			button_play.text = "Downloading..."
			timer_download_progress_mod.start()
			var error = http_request_mod.request(mod)
			if error != OK:
				accept_dialog.dialog_text = "An error (%s) occurred while creating the HTTP request." % error
				accept_dialog.show()
	elif not mod_needs_install:
		mod_ready_to_play.emit()


func _on_http_request_mod_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		accept_dialog.dialog_text = "An error (%s) occurred in the HTTP request." % result
		accept_dialog.show()
		return

	progress_bar_download_mod.visible = false
	timer_download_progress_mod.stop()
	button_play.text = "Installing..."
	var file := FileAccess.open("user://novr.zip", FileAccess.WRITE)
	file.store_buffer(body)

	var thread = Thread.new()
	thread.start(_thread_install_mod)


func _on_timer_download_progress_launcher_timeout() -> void:
	var body_size := http_request_launcher.get_body_size()
	if body_size > 0:
		progress_bar_download_launcher.visible = true
	var downloaded_bytes := http_request_launcher.get_downloaded_bytes()

	var percent := int(downloaded_bytes * 100 / body_size)
	progress_bar_download_launcher.value = percent


func _on_timer_download_progress_mod_timeout() -> void:
	var body_size := http_request_mod.get_body_size()
	if body_size > 0:
		progress_bar_download_mod.visible = true
	var downloaded_bytes := http_request_mod.get_downloaded_bytes()

	var percent := int(downloaded_bytes * 100 / body_size)
	progress_bar_download_mod.value = percent


func _on_file_dialog_installation_dir_selected(dir: String) -> void:
	config.set_value(
		"Launcher",
		"installation_path",
		dir
	)
	config.save(CONFIG_PATH)
	installation_path = dir
