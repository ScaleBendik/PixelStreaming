How to use files in this directory:

- start.bat : Starts the signalling server with basic settings
- common.bat : Contains a bunch of helper functions for the contained scripts. Shouldn't be run directly.
- start_dev_turn.bat : Starts Wilbur with ScaleWorld-specific runtime config, secrets, and status publishing
- start_streamer_stack.bat : Canonical Windows launcher for Wilbur + Unreal + watchdog
- start_unreal.bat : Starts the ScaleWorld Unreal runtime
- start_watchdog.bat : Starts the host watchdog
- prepare_data_drive.bat : Prepares the update data drive
- run_unreal_update.bat : Runs a manual Unreal update by exact ZIP key

Deprecated compatibility wrapper:
- start_stack.bat : Redirects to start_streamer_stack.bat

Tips:

- You can provide --help to start.bat to get a list of customizable arguments.
- Values passed to these scripts cannot contain ^ or ! characters. cmd.exe
  doubles a caret when the scripts hand their arguments to common.bat, and
  strips an exclamation mark under delayed expansion, so a TURN password such
  as "pass!word" arrives as "password" with no error. Choose credentials
  without those two characters.
