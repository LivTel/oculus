#!/bin/tcsh
# Script to do a single $exptime exposure via indiserver library
# 	Oculus all-sky uses 30sec
#	skycamT still testing. 10sec - 30sec seems about right
#
# Uses indi config item, UPLOAD_SETTINGS.UPLOAD_DIR. You may need to upgrade the
# indiserver on oculus before this script can be used. The indiserver originally
# installed on oculus did not have that config item.
#
# Original function code that actually takes images: IAS 12th June 2014
# All the wrappers, locks, xfer, FITS headers etc: RJS 13th June 2014
# Extended to use per instrument config files, RJS, Feb 2019
#
# The indiserver we connect to is started on boot in /etc/rc.local or
# via the ICS autobooter as it needs to run as root.
#
# The camera USB needs to be plugged in on boot therefore.

#
# Start up configs
#
alias datestamp 'date +"%h %d %H:%M:%S"'
set procname = indi_skycam.csh
set hostname = `hostname -s`
set LOGFILE = /icc/log/indi_skycam_${hostname}.log
echo `datestamp` $hostname ${procname}: "Invoking indi_skycam $1 $2" >> $LOGFILE

# Parse command line
if ($#argv == 0) goto syntax

set FORCE_INIT = 0
set FORCE_DOME = 0
foreach par ($argv)
  if ("$par" == "--forceinit") then
    set FORCE_INIT = 1
    if ($DEBUG) echo `datestamp` $hostname ${procname}: "forceinit has been set" >> $LOGFILE
  else if ("$par" == "--forcedome") then
    set FORCE_DOME = 1
    if ($DEBUG) echo `datestamp` $hostname ${procname}: "forcedome has been set" >> $LOGFILE
  else if (-e "$par") then
     source "$par"
  else 
    goto syntax
  endif
end

#DEBUG is set in the config file but can be overridden here
#set DEBUG = 1


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
  set pidfound = `ps -elf | grep $procname | awk '($4=='$pid')' | wc -l`
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

if ($DEBUG) echo `datestamp` $hostname ${procname}: Lockfiles complete. Proceed to checking dome >> $LOGFILE




########################################
# Only take an image if the dome is open
########################################

# http://192.168.4.1/teldata takes several seconds to be generated, so we need to make sure we have not
# collected a half written version. If we have then we just try again. The loopct is here so that 
# we do not get into an infinite loop of the http://192.168.4.1/teldata system fails. We will give up 
# after five attempts.
set loopct = 0
while ( $loopct < 5 ) 
  if ($DEBUG) then
    wget http://192.168.4.1/teldata -O /tmp/teldata >>& $LOGFILE
  else 
    wget http://192.168.4.1/teldata -O /tmp/teldata >>& /dev/null
  endif
  # grep for what we know should be in the completed teldata file and if it is there then break from the loop 
  grep "Object recvd" /tmp/teldata >& /dev/null
  if ($status == 0) break 			# Good. Required data found. Jump out of loop
  if ($DEBUG) echo "/tmp/teldata does not contain the string 'Object recvd'" >> $LOGFILE
  if ($DEBUG) cat /tmp/teldata >> $LOGFILE
  if ($DEBUG) echo `datestamp` $hostname ${procname}: "Retry wget after a 2 sec sleep" >> $LOGFILE
  sleep 2
  @ loopct++
end

# Send stderr to /dev/null because I don't care if the file does not exist 
rm /tmp/enclosure-open /tmp/enclosure-closed >& /dev/null

tail -1 /tmp/teldata | grep "OPEN" >! /tmp/enclosure-open
tail -1 /tmp/teldata | grep "CLOSED" >! /tmp/enclosure-closed

# Check if either dome is open or the --forcedome option was set
if ($FORCE_DOME) then
  if ($DEBUG) echo `datestamp` $hostname ${procname}: "Enclosure ignored by --forcedome option" >> $LOGFILE
else
  if (!(-z /tmp/enclosure-closed)) then 
    if ($DEBUG) echo `datestamp` $hostname ${procname}: "enclosure closed" >> $LOGFILE
    goto ENC_CLOSED
  endif
  if ($DEBUG) echo `datestamp` $hostname ${procname}: "enclosure open" >> $LOGFILE
endif


######################
# CONFIGURE THE CAMERA
######################

set CONNECT_STATE = `indi_getprop -1 -p 7264 "${HARDWARE_NAME}.CONNECTION.CONNECT"`
if ( ($FORCE_INIT) || ("$CONNECT_STATE" != "On") ) then
  echo `datestamp` $hostname ${procname}: "Reconnect to indiserver" >> $LOGFILE
  indi_setprop -p 7264 "${HARDWARE_NAME}.CONNECTION.CONNECT=On"
  sleep 3

  # The hypothesis is that these parameters only need to be checked after reconnecting
  # to the server. We think (untested) that as long as we remain connected to a single session
  # there is no reason why any of these configs should get lost.

  # Set output directory and filename. 
  indi_setprop -p 7264 "${HARDWARE_NAME}.UPLOAD_SETTINGS.UPLOAD_DIR=${datadir};UPLOAD_PREFIX=${inst_letter}_IMAGE_XX"
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
else
  if ($DEBUG) then
    echo `datestamp` $hostname ${procname}: "indiserver already connected. Not reconnecting." >> $LOGFILE
    indi_getprop -p 7264 "${HARDWARE_NAME}.UPLOAD_SETTINGS.*" >> $LOGFILE
    indi_getprop -p 7264 "${HARDWARE_NAME}.CCD_BINNING.*" >> $LOGFILE
  endif
endif

# Set a 45 second timeout, which all subsequent CCD activity must take place in
# According to the docs, it is not clear this is needed
# Comment out for testing. It may need to be replaced.
#indi_getprop -p 7264 -t 45 "${HARDWARE_NAME}.CONNECTION.CONNECT" >> /dev/null &



#####################################################
# COLLECT VALUES THAT WILL NEED TO GO INTO THE HEADER
#####################################################

# delete old temporary output file if there is one
rm -f "${datadir}/${inst_letter}_IMAGE_"*.fits >& /dev/null

# generate LT style standard filename
set fname = ` $FILENAME EXPOSE $inst_letter $datadir `
if ($DEBUG) echo `datestamp` $hostname ${procname}:  File name will be $fname >> $LOGFILE

# Will get written in FITS header later
set ccdatemp = `indi_getprop -1 -p 7264 "${HARDWARE_NAME}.CCD_TEMPERATURE.CCD_TEMPERATURE_VALUE"`

# Record the LMST now, before the integration. It is not accurately the time the shutter opened
# but it is close enough for most purposes. 
set lmst = ` $LMST `
#if ($DEBUG) echo `datestamp` $hostname ${procname}:  LMST = $lmst >> $LOGFILE



##################
# ACTUAL EXPOSURES
##################

# Take a $MULTRUN x $EXPTIME multrun
set ct = 0
while($ct < $MULTRUN)
  if ($DEBUG) echo `datestamp` $hostname ${procname}:  Start $EXPTIME sec exposure >> $LOGFILE
  indi_setprop -p 7264 "${HARDWARE_NAME}.CCD_EXPOSURE.CCD_EXPOSURE_VALUE=${EXPTIME}"
  sleep $OVERHEAD
  @ ct++
  while ( `indi_getprop -1 -p 7264 "${HARDWARE_NAME}.CCD_EXPOSURE.CCD_EXPOSURE_VALUE" ` )
    if ($DEBUG) printf "."  >> $LOGFILE
    sleep 1
  end
  if ($DEBUG) printf "\n"  >> $LOGFILE
end


# Check the expected output file exists 
if (! -e ${datadir}/${inst_letter}_IMAGE_01.fits ) then
  echo `datestamp` $hostname ${procname}: "ERROR : No output image (${datadir}/${inst_letter}_IMAGE_01.fits) from indiserver" >> $LOGFILE

  # Disconnect from the server. That will force the script to reconnect and attempt to reinitialise everything next time
  echo `datestamp` $hostname ${procname}: " Disconnect from indiserver" >> $LOGFILE
  indi_setprop -p 7264 "${HARDWARE_NAME}.CONNECTION.DISCONNECT=On"
  sleep 3
  indi_getprop -p 7264 "${HARDWARE_NAME}.CONNECTION.CONNECT" >> $LOGFILE

  exit 1
else 

  # Rename the indi output file to LT standard filename
  # In fact indiserver is capable of doing this itself now. See note in UPLOAD configs above.

  mv "${datadir}/${inst_letter}_IMAGE_01.fits" $fname

  if ($DEBUG) echo `datestamp` $hostname ${procname}: Update all the FITS headers in $fname >> $LOGFILE
  # Add LST to the FITS header. This is LST just before the oculus code was called, not the moment the shutter opened
  $FAKV $fname LST STRING "${lmst}"

  $FAKV $fname AZDMD DOUBLE `grep "Azimuth demand" /tmp/teldata | awk '{print $4}' `
  $FAKV $fname AZIMUTH DOUBLE `grep "Current Azimuth position" /tmp/teldata | awk '{print $4}'`
  $FAKV $fname AZSTAT STRING `grep "Azimuth status" /tmp/teldata | awk '{print $4}'`

  $FAKV $fname ALTDMD DOUBLE `grep "Altitude demand" /tmp/teldata | awk '{print $4}'`
  $FAKV $fname ALTITUDE DOUBLE `grep "Current Altitude position" /tmp/teldata | awk '{print $4}'`
  $FAKV $fname ALTSTAT STRING `grep "Altitude status" /tmp/teldata | awk '{print $4}'`

  $FAKV $fname ENC1DMD STRING `grep "Enclosure shutter 1 demand" /tmp/teldata | awk '{print $6}'`
  $FAKV $fname ENC1POS STRING `grep "Enclosure shutter 1 current" /tmp/teldata | awk '{print $6}'`
  $FAKV $fname ENC2DMD STRING `grep "Enclosure shutter 2 demand" /tmp/teldata | awk '{print $6}'`
  $FAKV $fname ENC2POS STRING `grep "Enclosure shutter 2 current" /tmp/teldata | awk '{print $6}'`

  # Transcribe existing FITS keywords into our standard LT versions
  $FAKV $fname UTSTART STRING `$FGKV $fname DATE-OBS STRING `
  $FAKV $fname CCDXBIN INT `$FGKV $fname XBINNING INT `
  $FAKV $fname CCDYBIN INT `$FGKV $fname YBINNING INT `

  #LT convention is to write pixel dimension in m. This camera writes the value in micron
  #set pixsizemicron = `$FGKV $fname PIXSIZE1 INT `
  #set pixsizem = `echo "7k $pixsizemicron 1e6 / p" | dc`
  # But for now I am just going to transcribe the micron value
  $FAKVC $fname CCDXPIXE DOUBLE `$FGKV $fname PIXSIZE1 DOUBLE ` "um" "Physical pixel size"
  $FAKVC $fname CCDYPIXE DOUBLE `$FGKV $fname PIXSIZE2 DOUBLE ` "um" "Physical pixel size"

  # In quicksky, JMM uses keyword DATE in the form YYYY-MM-DD. I can create that from DATE-OBS
  $FAKV $fname DATE STRING `$FGKV $fname DATE-OBS STRING | sed 's/T.*//'`

  $FAKV $fname INSTRUME STRING $INSTRUMENT_NAME
  $FAKVC $fname CCDATEMP DOUBLE $ccdatemp "C" "Detector temperature"

  if ($DEBUG) echo `datestamp` $hostname ${procname}: Success. >> $LOGFILE
endif


######################################
# What to do if enclosure is closed
ENC_CLOSED:
#nothing!

# cleanup gets done at the end of any run but we also jump here automatically if
# the script process gets killed
cleanup:
/usr/bin/lockfile-remove $LOCK

if ($DEBUG) echo `datestamp` $hostname ${procname}: Exit script. >> $LOGFILE
exit 0

syntax:
    echo `datestamp` $hostname ${procname}: Command line syntax error >> $LOGFILE
    echo "Syntax: indi_skycam.csh <configfile> [--forceinit] [--forcedome]"
    echo "\tconfigfile is fully qualified path to mandatory configuration file"
    echo "\tOptional flag --forceinit reconnects to the indiserver even if already connected."
    echo "\tOptional flag --forcedome takes exposure even if enclosure is closed."
    exit 2
