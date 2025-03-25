# This 'setup' script is intended to source by both the exposure and darks scripts
# to ensure that both are being initiated in exactly the same way.

# source it rather than execute to make sure everything is going into the correct runtime environment

# This saetup does
#  * Setup log files
#  * Set external helper executables
#  * command line syntax parse (maybe that should go back into the calling script?
#  * lockfiles
#  * initialise the camera head
#
# The calling script can then 
#  * check dome is open| closed, depending on ehat it wants
#  * take the actual exposures that it wants


#
# Start up configs
#
alias datestamp 'date +"%h %d %H:%M:%S"'
set procname = indi_skycam_setup.csh
set hostname = `hostname -s`
set LOGFILE = /icc/log/indi_skycam_${hostname}.log
echo `datestamp` $hostname ${procname}: "Invoking $procname on behalf of $0 $argv " >> $LOGFILE

#set DEBUG = 0
set DEBUG = 1

# Parse command line
if ($#argv == 0) then
    echo `datestamp` $hostname ${procname}: Command line syntax error >> $LOGFILE
    echo "Syntax: indi_skycam_expose.csh|indi_skycam_auto_darks.csh  <configfile> [--forceinit] [--forcedome] [--forceteldata]"
    echo "\tconfigfile is fully qualified path to mandatory configuration file"
    echo "\tOptional flag --forceinit reconnects to the indiserver even if already connected."
    echo "\tOptional flag --forcedome takes exposure even if enclosure is closed."
    echo "\tOptional flag --forceteldata prevents the script even trying to look for the RCS teldata."
    echo "\t\t Using --forceteldata alone without --forcedome probably makes no sense. Use both."
    exit 2
endif

# FORCE_INIT (CLI "--forceinit")
#	lets you do the init commands every time even if the system thinks they are already correct
# FORCE_DOME (CLI "--forcedome")
# 	lets you ignore the dome and take data anyway, but it does still need the dome data to be there.
# 	If the wget that retrieve the dome daat from the occ fails, then we still cannot run. 
# 	Fix that to also allow ignoring occ and RCS wget failures?
# FORCE_TELDATA (CLI "--forceteldata")
#	lets you ignore teldata from the RCS. This is probably never useful in operations or even on
#	site at all, but it does let you run this script on the bench in Liverpool and not even try
#       to look for the RCS. 
#       If you use "--forceteldata", you almost certainly actually want both "--forceteldata --forcedome"
set FORCE_INIT = 0
set FORCE_DOME = 0
set FORCE_TELDATA = 0
foreach par ($argv)
  if ("$par" == "--forceinit") then
    set FORCE_INIT = 1
    if ($DEBUG) echo `datestamp` $hostname ${procname}: "forceinit has been set" >> $LOGFILE
  else if ("$par" == "--forcedome") then
    set FORCE_DOME = 1
    if ($DEBUG) echo `datestamp` $hostname ${procname}: "forcedome has been set" >> $LOGFILE
  else if ("$par" == "--forceteldata") then
    set FORCE_TELDATA = 1
    if ($DEBUG) echo `datestamp` $hostname ${procname}: "forceteldata has been set" >> $LOGFILE
  else if (-e "$par") then
     source "$par" >> $LOGFILE
     #DEBUG is set in the config file but can be overridden here, after source-ing the config file.
     #set DEBUG = 1
  else 
    goto syntax
  endif
end


# Set explicit paths to all the external helper applications
# More robust than relying on $PATH
# These could go to $CONFIGFILE if you want to set them per camera
set datadir = /icc/tmp
cd $datadir
set execdir = /usr/local/bin
set FILENAME = ${execdir}/filename
set LMST = ${execdir}/lmst
set FGKV = ${execdir}/fits_get_keyword_value_static
set FAKV = ${execdir}/fits_add_keyword_value_static
set FAKVC = ${execdir}/fits_add_keyword_value_comment_static

set LOCK = /tmp/indi_skycam



###########
# Lockfiles
###########
if ($DEBUG) echo `datestamp` $hostname ${procname}: Check lockfile >> $LOGFILE
/usr/bin/lockfile-check $LOCK 
if ($? == 0) then
  if ($DEBUG) echo `datestamp` $hostname ${procname}: Lockfile exists >> $LOGFILE
  set pid = `cat ${LOCK}.lock`
  if ($DEBUG) echo `datestamp` $hostname ${procname}: pid in ${LOCK}.lock is $pid >> $LOGFILE
  set pidfound = `ps -elf | grep indi_skycam | awk '($4=='$pid')' | wc -l`
  if ($DEBUG) ps -elf | grep indi_skycam | awk '($4=='$pid')' >> $LOGFILE
  if ($DEBUG) echo `datestamp` $hostname ${procname}: pidfound = $pidfound >> $LOGFILE
  if($pidfound != 0) then
    if ($DEBUG) echo `datestamp` $hostname ${procname}: "By running ps it looks like exposures are underway. Aborted."
      echo `datestamp` $hostname ${procname}: "By running ps it looks like exposures are underway. Aborted." >> $LOGFILE
      exit 1
    else
      if ($DEBUG) echo "By running ps it looks like this is an out of date lock file. It has been deleted and exposures will proceed."
      echo "By running ps it looks like this is an out of date lock file. It has been deleted and exposures will proceed." >> $LOGFILE
      /usr/bin/lockfile-remove $LOCK
    endif
  endif
endif

# Create lock file
if ($DEBUG) echo `datestamp` $hostname ${procname}: Create lockfile >> $LOGFILE
/usr/bin/lockfile-create --use-pid --retry 0 $LOCK
if ($?) then
    echo "** Error: Unable to create lockfile: $LOCK " >> $LOGFILE
    exit 2
endif

# Now we have a lockfile created, we need to enfore cleanup at the end
onintr cleanup

if ($DEBUG) echo `datestamp` $hostname ${procname}: Lockfiles complete. >> $LOGFILE






######################
# CONFIGURE THE CAMERA
######################
if ($DEBUG) echo `datestamp` $hostname ${procname}: Configure the camera. >> $LOGFILE
set CONNECT_STATE = `indi_getprop -1 -p 7264 "${HARDWARE_NAME}.CONNECTION.CONNECT"`
if ( ($FORCE_INIT) || ("$CONNECT_STATE" != "On") ) then
  echo `datestamp` $hostname ${procname}: "Reconnect to indiserver" >> $LOGFILE
  indi_setprop -p 7264 "${HARDWARE_NAME}.CONNECTION.CONNECT=On"
  sleep 3

  # The hypothesis is that these parameters only need to be checked after reconnecting
  # to the server. We think (untested) that as long as we remain connected to a single session
  # there is no reason why any of these configs should get lost.

  # Set output directory and filename. 
  # On all previous cameras this was "UPLOAD_PREFIX=${inst_letter}_IMAGE_XX". The _XX got automatically replaced with a number by indi.
  # The latest indi for zwo_asi174mm seems to need "UPLOAD_PREFIX=${inst_letter}_IMAGE_XXX". If you put _XX, then it uses a literal "XX" string.
  # Untested if _XXX is backwards compatible and can be used on the older cameras. If it can then we set _XXX on them all. If not then 
  # this needs to be moved out into the config file.
  indi_setprop -p 7264 "${HARDWARE_NAME}.UPLOAD_SETTINGS.UPLOAD_DIR=${datadir};UPLOAD_PREFIX=${inst_letter}_IMAGE_XXX"
  #
  # On older indi we had to write the file out and then use the "filename" executable to generate
  # a new LT-like filename. That is no longer required. On current indiserver we can set a full
  # LT filename with the command
  #indi_setprop -p 7264 "${HARDWARE_NAME}.UPLOAD_SETTINGS.UPLOAD_DIR=${datadir};UPLOAD_PREFIX=${inst_letter}_e_20190213_XXX_1_1_0"
  # We would however have to set the yyyymmdd date carefully from here. Currently that is handled by
  # the filename executable
  #
  if ($DEBUG) indi_getprop -p 7264 "${HARDWARE_NAME}.UPLOAD_SETTINGS.*" >> $LOGFILE

  # Put server into "write local file" mode
  indi_setprop -p 7264 "${HARDWARE_NAME}.UPLOAD_MODE.UPLOAD_LOCAL=On"
  if ($DEBUG) indi_getprop -p 7264 "${HARDWARE_NAME}.UPLOAD_MODE.UPLOAD_LOCAL" >> $LOGFILE

  # Set the binning from values in the config file
  indi_setprop -p 7264 "${HARDWARE_NAME}.CCD_BINNING.HOR_BIN=$XBIN;VER_BIN=$YBIN"
  if ($DEBUG) indi_getprop -p 7264 "${HARDWARE_NAME}.CCD_BINNING.*" >> $LOGFILE

  # The ZWO CCD ASI174MM camera appears to need the GAIN and OFFSET setting.
  if ( ${?GAIN} ) then
    indi_setprop -p 7264 "${HARDWARE_NAME}.CCD_CONTROLS.Gain=$GAIN"
    if ($DEBUG) indi_getprop -p 7264 "${HARDWARE_NAME}.CCD_CONTROLS.Gain" >> $LOGFILE
  else
    echo "Not configuring GAIN - it is not set."
  endif
  if ( ${?OFFSET} ) then
    indi_setprop -p 7264 "${HARDWARE_NAME}.CCD_CONTROLS.Offset=$OFFSET"
    if ($DEBUG) indi_getprop -p 7264 "${HARDWARE_NAME}.CCD_CONTROLS.Offset" >> $LOGFILE
  else
    echo "Not configuring OFFSET - it is not set."
  endif

  # Image flipping in X/horizontal
  if ( ${?FLIP_X} ) then
    indi_setprop -p 7264 "${HARDWARE_NAME}.FLIP.FLIP_HORIZONTAL=$FLIP_X"
    if ($DEBUG) indi_getprop -p 7264 "${HARDWARE_NAME}.FLIP.FLIP_HORIZONTAL" >> $LOGFILE
  else
    echo "Not setting image flipping in X - it is not set."
  endif
  # Image flipping in Y/vertical
  if ( ${?FLIP_Y} ) then
    indi_setprop -p 7264 "${HARDWARE_NAME}.FLIP.FLIP_VERTICAL=$FLIP_Y"
    if ($DEBUG) indi_getprop -p 7264 "${HARDWARE_NAME}.FLIP.FLIP_VERTICAL" >> $LOGFILE
  else
    echo "Not setting image flipping in Y - it is not set."
  endif
else
  if ($DEBUG) then
    echo `datestamp` $hostname ${procname}: "indiserver already connected. Not reconnecting." >> $LOGFILE
    indi_getprop -p 7264 "${HARDWARE_NAME}.UPLOAD_SETTINGS.*" >> $LOGFILE
    indi_getprop -p 7264 "${HARDWARE_NAME}.CCD_BINNING.*" >> $LOGFILE
    indi_getprop -p 7264 "${HARDWARE_NAME}.CCD_CONTROLS.*" >> $LOGFILE
    indi_getprop -p 7264 "${HARDWARE_NAME}.FLIP.*" >> $LOGFILE
  endif
endif

# Set a 45 second timeout, which all subsequent CCD activity must take place in
# According to the docs, it is not clear this is needed
# Comment out for testing. It may need to be replaced.
#indi_getprop -p 7264 -t 45 "${HARDWARE_NAME}.CONNECTION.CONNECT" >> /dev/null &



if ($DEBUG) echo `datestamp` $hostname ${procname}: Init complete Back to the calling script >> $LOGFILE



