@ECHO OFF
CD /D "%~dp0" >nul
SET THISBAT=%~0
SET THISPATH=%~dp0
IF "%~1" == "-hex" (
	REM Work-around for calling batch-label inside a for loop
	CALL :DecToHex "%~2"
	EXIT /B %ERRORLEVEL%
)

SETLOCAL enableextensions enabledelayedexpansion
SET PARTITION_LIST_FILE=None
SET ERROR=0

:: Rotate log
IF EXIST log.txt (
	IF EXIST log.previous.txt (
		DEL log.previous.txt
	)
	MOVE log.txt log.previous.txt
)


CALL :CLEAR_TITLE

:: load config
ECHO [#] Reading configured COM port...
CALL :READ_CONFIG_INI COMPort CONFIG_COMPORT
ECHO         %CONFIG_COMPORT%
ECHO [#] Reading configured Firehose loader binary path...
CALL :READ_CONFIG_INI FirehoseLoader CONFIG_LOADER
ECHO         %CONFIG_LOADER%
ECHO [#] Reading configured transfer speed...
CALL :READ_CONFIG_INI TransferSpeed CONFIG_SPEED
ECHO         %CONFIG_SPEED%
ECHO.

:MAIN_MENU
ECHO [i] Make your choice:
ECHO.
ECHO     1) Set partition list file [list of partitions to backup]
ECHO         Current = %PARTITION_LIST_FILE%
ECHO.
ECHO     2) Backup all partitions from partition list file
ECHO.
ECHO     3) Restore a backup
ECHO.
ECHO     4) Advanced...
ECHO.
ECHO     5) Quit
ECHO.
ECHO.
SET CHOICE_MAIN=
ECHO [#] Enter number: 
SET /P CHOICE_MAIN=
ECHO.

IF "%CHOICE_MAIN%"=="1" (
	CALL :CHOICE_SET_PARTITION_LIST
) ELSE IF "%CHOICE_MAIN%"=="2" (
	CALL :CHOICE_BACKUP
) ELSE IF "%CHOICE_MAIN%"=="3" (
	CALL :CHOICE_RESTORE
) ELSE IF "%CHOICE_MAIN%"=="4" (
	ECHO.
	ECHO [i] Nothing here yet...
) ELSE IF "%CHOICE_MAIN%"=="5" (
	GOTO :EOF
) ELSE (
	ECHO [^^!] Invalid option.
)
:ERROR_END
SET ERROR=0
REM clean the log file
IF EXIST "%THISPATH%\log.txt" (
	FINDSTR /V "Sectors remaining " "%THISPATH%\log.txt" > "%THISPATH%\log.clean.txt"
	MOVE /Y "%THISPATH%\log.clean.txt" "%THISPATH%\log.txt" >nul
)
ECHO.
ECHO [i] Press any key to return to main menu.
PAUSE
CALL :CLEAR_TITLE
GOTO :MAIN_MENU

:ERROR
ECHO.
ECHO 	[^^!] An error occured. %~1. Check device connection and COM port is correct.
ECHO 	    See log.txt for details.
ECHO.
GOTO :EOF

:CHOICE_SET_PARTITION_LIST
ECHO [i] Found partition lists:
ECHO.
SET COUNT=1
FOR %%F IN (partition_list.*.txt) DO (
	SET CHOICE_!COUNT!=%%F
	ECHO 	!COUNT!^) %%F
	SET COMMENT=
	FOR /F "delims=" %%C IN ('TYPE %%F') DO (
		IF "!COMMENT!"=="" (
			SET COMMENT=%%C
		)
	)
	ECHO 		!COMMENT!
	SET /A COUNT=!COUNT!+1
)
ECHO.
ECHO [#] Select desired partition list: 
SET /P CHOICE_PARTLIST=
ECHO.
FOR %%N IN (!CHOICE_PARTLIST!) DO SET CHOICE_PARTLIST=!CHOICE_%%N!
IF EXIST !CHOICE_PARTLIST! (
	SET PARTITION_LIST_FILE=!CHOICE_PARTLIST!
	ECHO [i] Selected '!PARTITION_LIST_FILE!'.
) ELSE (
	ECHO [^^!] Invalid choice.
)
GOTO :EOF

:CHOICE_BACKUP
REM Verify the partition list exists
IF EXIST %PARTITION_LIST_FILE% (
	ECHO [#] Enter folder name or full/relative path to store the backup [must not already exist]: 
	SET /P CHOICE_BACKUPPATH=
	IF "!CHOICE_BACKUPPATH!"=="" (
		ECHO [^^!] You must enter a path. Just a name of subfolder is enough.
	) ELSE IF EXIST !CHOICE_BACKUPPATH! (
		ECHO [^^!] Folder or file of that name already exists.
	) ELSE (
		REM Got backup path
		MKDIR !CHOICE_BACKUPPATH!
		ECHO [#] Press any key to start backup. This may take some time. You can check log.txt for detailed progress or
		ECHO     concerns of a freeze.
		PAUSE>NUL
		ECHO.
		FOR /F %%P IN (%PARTITION_LIST_FILE%) DO (
			SET PARTNAME=%%P
			IF NOT "!PARTNAME:~0,1!"=="#" (
				REM skip comments
				CALL :BACKUP_PART !PARTNAME! !CHOICE_BACKUPPATH!
				IF "!ERROR!"=="1" (
					CALL :ERROR "BACKUP IS INCOMPLETE."
					GOTO :ERROR_END
				)
			)
		)
		ECHO.
		ECHO [#] Dumping partition table info...
		ECHO # PartNum PartName StartSec NumSecs> "!CHOICE_BACKUPPATH!\partitiontable.tmp.txt"
		ECHO.>> "!CHOICE_BACKUPPATH!\partitiontable.tmp.txt"
		"%THISPATH%\bin\emmcdl.exe" -p %CONFIG_COMPORT% -f "%CONFIG_LOADER%" -gpt > "!CHOICE_BACKUPPATH!\tmp.txt"
		IF ERRORLEVEL 1 (
			CALL :ERROR "BACKUP IS INCOMPLETE"
			REM Copy the log here since we don't want to interfere with ERRORLEVEL
			TYPE "!CHOICE_BACKUPPATH!\tmp.txt" >> "%THISPATH%\log.txt"
			GOTO :ERROR_END
		)
		TYPE "!CHOICE_BACKUPPATH!\tmp.txt" >> "%THISPATH%\log.txt"
		REM Parse the GPT dump output
		FOR /F "delims=" %%L IN ('TYPE "!CHOICE_BACKUPPATH!\tmp.txt"') DO (
			SET LINE=%%L
			REM Check if this line begins with a digit
			IF "!LINE:~0,1!" GEQ "0" (
				IF "!LINE:~0,1!" LEQ "9" (
					REM Split on . and :, up to 12 tokens (starting at %%A, then %%B, etc)
					FOR /F "tokens=1-12 delims=.: " %%A IN ("!LINE!") DO (
						REM PartNum PartName StartLBA SizeInLBA
						ECHO %%A %%D %%G %%K>> "!CHOICE_BACKUPPATH!\partitiontable.tmp.txt"
					)
				)
			)
		)
		DEL "!CHOICE_BACKUPPATH!\tmp.txt"
		ECHO [#] Building rawprogram0.xml...
		REM Build rawprogram0.xml
		SET RAW_PROG_XML=!CHOICE_BACKUPPATH!\rawprogram0.xml
		ECHO ^<?xml version="1.0" ?^>>"!RAW_PROG_XML!"
		ECHO ^<data^>>>"!RAW_PROG_XML!"
		FOR /F "tokens=1-4" %%A IN ('TYPE "!CHOICE_BACKUPPATH!\partitiontable.tmp.txt"') DO (
			REM skip comments
			IF NOT "%%A"=="#" (
				FOR /F %%P IN (%PARTITION_LIST_FILE%) DO (
					IF "%%P" == "%%B" (
						REM Thanks to emuzychenko for this batch wizardry
						REM Calculate byte offset in 256-byte units to avoid overflow
						SET /A ByteOffset256=%%C * 2
						SET /A SizeInKB=%%D / 2
						FOR /F %%Z IN ('CALL "%THISBAT%" -hex !ByteOffset256!') DO SET ByteOffset256Hex=%%Z
						ECHO   ^<program SECTOR_SIZE_IN_BYTES="512" file_sector_offset="0" filename="%%B.img" label="%%B" num_partition_sectors="%%D" physical_partition_number="0" size_in_KB="!SizeInKB!.0" sparse="false" start_byte_hex="0x!ByteOffset256Hex!00L" start_sector="%%C"/^>>>"!RAW_PROG_XML!"
					)
				)
			)
		)
		echo ^</data^>>>"!RAW_PROG_XML!"
		DEL "!CHOICE_BACKUPPATH!\partitiontable.tmp.txt"
		ECHO [i] All done^^!
	)
) ELSE (
	ECHO [^^!] Partition list invalid [not found or not set]. Please do it first.
)
GOTO :EOF

:CHOICE_RESTORE
ECHO [#] Enter folder name or full/relative path of backup to restore: 
SET /P CHOICE_BACKUPPATH=
IF "!CHOICE_BACKUPPATH!"=="" (
	ECHO [^^!] You must enter a path. Just a name of subfolder is enough.
) ELSE IF NOT EXIST !CHOICE_BACKUPPATH! (
	ECHO [^^!] Folder or file of that name could not be found.
) ELSE (
	REM Got backup path, verify it
	CALL :RESTORE_VERIFY_PATH !CHOICE_BACKUPPATH!
	IF "!ERROR!"=="1" (
		ECHO 	[^^!] An error occured. Not a valid backup path [missing rawprogram0.xml].
		GOTO :ERROR_END
	)
	REM Verified, go!
	ECHO [#] Press any key to start restore. This may take some time. All output will be in the window [not the log] to show progress.
	PAUSE>NUL
	CD /D !CHOICE_BACKUPPATH!
	ECHO "%THISPATH%\bin\emmcdl.exe" -p %CONFIG_COMPORT% -f "%THISPATH%\%CONFIG_LOADER%" -x "!CD!\rawprogram0.xml" -MaxPayloadSizeToTargetInBytes %CONFIG_SPEED%
	"%THISPATH%\bin\emmcdl.exe" -p %CONFIG_COMPORT% -f "%THISPATH%\%CONFIG_LOADER%" -x "!CD!\rawprogram0.xml" -MaxPayloadSizeToTargetInBytes %CONFIG_SPEED%
	CD /D "%THISPATH%"
	ECHO.
	ECHO [i] All done^^!
)
GOTO :EOF

:RESTORE_VERIFY_PATH
IF NOT EXIST "%~1\rawprogram0.xml" (
	SET ERROR=1
	GOTO :EOF
)
GOTO :EOF

:BACKUP_PART
SET PART_NAME=%1
SET OUT="%~2\%1.img"
ECHO 	[#] Dumping "%PART_NAME%" to %OUT%...
"%THISPATH%\bin\emmcdl.exe" -p %CONFIG_COMPORT% -f "%CONFIG_LOADER%" -d %PART_NAME% -o %OUT% -MaxPayloadSizeToTargetInBytes %CONFIG_SPEED% >> "%THISPATH%\log.txt"
IF ERRORLEVEL 1 (
	SET ERROR=1
)
GOTO :EOF

REM Thanks to emuzychenko for this batch wizardry
:DecToHex
SETLOCAL enabledelayedexpansion
SET DecNum=%~1
SET DigTable=0123456789abcdef
SET HexRes=
:DecToHex_Loop
SET /A DecNumQ=%DecNum% / 16
SET /A DecRmd=%DecNum% - %DecNumQ% * 16
SET DecNum=%DecNumQ%
SET HexDig=!DigTable:~%DecRmd%,1!
SET HexRes=%HexDig%%HexRes%
IF %DecNum% NEQ 0 GOTO :DecToHex_Loop
ECHO %HexRes%
ENDLOCAL
GOTO :EOF

:CLEAR_TITLE
CLS
ECHO --------------------------------------------------------
ECHO -     Mi A1 Low-level Backup/Restore/Flashing tool     -
ECHO -                                                      -
ECHO -          By CosmicDan@XDA and CosmicDan.com          -
ECHO -    Based on EMMCDL scripts thanks to @emuzychenko    -
ECHO --------------------------------------------------------
ECHO.
ECHO.
GOTO :EOF

:: Credits to emil @ StackOverflow - https://stackoverflow.com/a/4518146/1767892
:: Syntax - CALL :READ_CONFIG_INI [INI_KEYNAME] [BAT_VARNAME]
:READ_CONFIG_INI
FOR /F "tokens=2 delims==" %%k IN ('find "%~1=" config.ini') DO SET %~2=%%k
GOTO :EOF