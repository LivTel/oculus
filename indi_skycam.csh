#!/bin/tcsh
# Script to do a 30 second exposure via indiserver library
# 	Oculus all-sky uses 30sec
#	skycamT we will try 1x30sec initiall. It may need 3x10sec?
#
# Original function code that actually takes images: IAS 12th June 2014
# All the wrappers, locks, xfer, FITS headers etc: RJS 13th June 2014
#
# The indiserver we connect to is started on boot in /etc/rc.local or
# via the ICS autobooter as it needs to run as root.
#
# The camera USB probably needs to be plugged in on boot therefore.

# 
# Start up configs
#

alias datestamp 'date +"%h %d %H:%M:%S"'
set procname = indi_skycam.csh
set hostname = `hostname -s`

set CONFIGFILE = "$1"
if (-e "$CONFIGFILE") then
  source $CONFIGFILE
else
  echo "Syntax: indi_skycam.csh <configfile>"
  echo "\tconfigfile is fully qualified path to mandatory configuration file"
  exit 2
endif

#DEBUG is set in $CONFIGFILE but can be overridden here
#set DEBUG = 1

set LOGFILE = /icc/log/indi_skycam_${hostname}.log

# Set explicit paths to all the external helper applications
# More robust than relying on $PATH
# These could go to $CONFIGFILE if you want to set them per camera
set execdir = /usr/local/bin
set datadir = /icc/tmp
set FILENAME = ${execdir}/filename
set LMST = ${execdir}/lmst
set FGKV = ${execdir}/fits_get_keyword_value_static
set FAKV = ${execdir}/fits_add_keyword_value_static
set FAKVC = ${execdir}/fits_add_keyword_value_comment_static

if ($DEBUG) echo `datestamp` $hostname ${procname}: "Invoking indi_skycam" >> $LOGFILE



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

if (!(-z /tmp/enclosure-closed)) then 
  if ($DEBUG) echo `datestamp` $hostname ${procname}: "enclosure closed" >> $LOGFILE
  goto ENC_CLOSED
endif
if ($DEBUG) echo `datestamp` $hostname ${procname}: "enclosure open" >> $LOGFILE



# Make sure we are connected to camera
indi_setprop -p 7264 "${HARDWARE_NAME}.CONNECTION.CONNECT=On"
sleep 3

# Set a 45 second timeout, which all subsequent CCD activity must take place in
# According to the docs, it is not clear this is needed
# Comment out for testing. It may need to be replaced.
#indi_getprop -p 7264 -t 45 "${HARDWARE_NAME}.CONNECTION.CONNECT" >> /dev/null &

# Set the binning from values in the config file
indi_setprop -p 7264 "${HARDWARE_NAME}.CCD_BINNING.HOR_BIN=$XBIN;VER_BIN=$YBIN"
if ($DEBUG) indi_getprop -p 7264 "${HARDWARE_NAME}.CCD_BINNING.*" >> $LOGFILE

# Set output directory. This should be set in the indiserver defaults.
# It is not clear we really need to reset it every time
indi_setprop -p 7264 "${HARDWARE_NAME}.UPLOAD_SETTINGS.UPLOAD_DIR=${datadir};UPLOAD_PREFIX=${inst_letter}_IMAGE_XX"
if ($DEBUG) indi_getprop -p 7264 "${HARDWARE_NAME}.UPLOAD_SETTINGS.*" >> $LOGFILE

# delete old temporary output file if there is one
rm -f "${datadir}/${inst_letter}_IMAGE_"*.fits >& /dev/null

# Record the LMST now, before the integration. It is not accurately the time the shutter opened
# but it is close enough for most purposes. 
set lmst = ` $LMST `

#take a 30 second exposure
indi_setprop -p 7264 "${HARDWARE_NAME}.CCD_EXPOSURE.CCD_EXPOSURE_VALUE=30"

#wait 40 seconds for exposure to complete
#indi_getprop -p 7264 "${HARDWARE_NAME}.CCD_EXPOSURE.CCD_EXPOSURE_VALUE"
#gradually counts down to 0, so we could also watch that instead of just waiting 40sec.
sleep 40

#generate LT style standard filename and rename/move temporary image
set fname = ` $FILENAME EXPOSE $inst_letter $datadir `

# Oculus by default creates FITS with the name SX\ CCD\ SuperStar.CCD1.CCD1.fits
mv "${datadir}/${inst_letter}_IMAGE_01.fits" $fname

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

# Could also get the CCD temperature from indiserver if you like
# SX CCD SXVR-H35.CCD_TEMPERATURE.CCD_TEMPERATURE_VALUE=-20.300000000000000711



######################################
# What to do if enclosure is closed

ENC_CLOSED:

exit 0
 
[eng@ltdevsrv oculus]$   
[eng@ltdevsrv oculus]$ 
[eng@ltdevsrv oculus]$ 
[eng@ltdevsrv oculus]$ 
[eng@ltdevsrv oculus]$ 
[eng@ltdevsrv oculus]$ 
[eng@ltdevsrv oculus]$ 
[eng@ltdevsrv oculus]$ 
[eng@ltdevsrv oculus]$ more oculus.csh
#!/bin/csh
# Script to do a 30 second oculus exposure via indiserver library
# It needs to use the execution directory to write a temporary output file.
# This is a limitation of the way we simply call the device from command line.
#
# Original function code that actually takes images: IAS 12th June 2014
# All the wrappers, locks, xfer, FITS headers etc: RJS 13th June 2014
#
# The indiserver we connect to is started on boot in /etc/rc.local as it needs
# to run as root.
# The camera USB probably needs to be plugged in on boot therefore.


# 
# Start up configs
#

alias datestamp 'date +"%h %d %H:%M:%S"'
set procname = oculus.csh
set hostname = `hostname -s`

set DEBUG = 1
set LOGFILE = /icc/log/oculus.log

# Set explicit paths to all the external helper applications
# More robust than relying on $PATH
set execdir = /usr/local/bin
set datadir = /icc/tmp
set FILENAME = ${execdir}/filename
set LMST = ${execdir}/lmst
set FGKV = ${execdir}/fits_get_keyword_value_static
set FAKV = ${execdir}/fits_add_keyword_value_static
set FAKVC = ${execdir}/fits_add_keyword_value_comment_static

if ($DEBUG) echo `datestamp` $hostname ${procname}: "Invoking oculus" >> $LOGFILE



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

if (!(-z /tmp/enclosure-closed)) then 
  if ($DEBUG) echo `datestamp` $hostname ${procname}: "enclosure closed" >> $LOGFILE
  goto ENC_CLOSED
endif
if ($DEBUG) echo `datestamp` $hostname ${procname}: "enclosure open" >> $LOGFILE




# Make sure we are connected to camera
indi_setprop -p 7264 "SX CCD SuperStar.CONNECTION.CONNECT=On"
sleep 3

# delete old temporary output file if there is one
rm -f SX\ CCD\ SuperStar.CCD1.CCD1.fits

#set a 45 second timeout, which all subsequent CCD activity must take place in
indi_getprop -p 7264 -t 45 &

# Record the LMST now, before the integration. It is not accurately the time the shutter opened
# but it is close enough for most purposes. 
set lmst = ` $LMST `

#take a 30 second exposure
indi_setprop -p 7264 "SX CCD SuperStar.CCD_EXPOSURE.CCD_EXPOSURE_VALUE=30"

#wait 40 seconds for exposure to complete
sleep 40

#generate LT style standard filename and rename/move temporary image
#set fname = `/home/eng/bin/filename EXPOSE a $datadir `
set fname = ` $FILENAME EXPOSE a $datadir `
mv SX\ CCD\ SuperStar.CCD1.CCD1.fits $fname

# Add LST to the FITS header. This is LST just before the oculus code was called, not the moment the shutter opened
$FAKV $fname LST STRING "${lmst}"

$FAKV $fname AZDMD DOUBLE `grep "Azimuth demand" /tmp/teldata | awk '{print $4}'`

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
#LT convension is to write pixel dimension in m. This camera writes the value in micron
#set pixsizemicron = `$FGKV $fname PIXSIZE1 INT `
#set pixsizem = `echo "7k $pixsizemicron 1e6 / p" | dc`
# But for now I am just going to transcribe the micron value
$FAKVC $fname CCDXPIXE DOUBLE `$FGKV $fname PIXSIZE1 DOUBLE ` "um" "Physical pixel size"
$FAKVC $fname CCDYPIXE DOUBLE `$FGKV $fname PIXSIZE2 DOUBLE ` "um" "Physical pixel size"
# In quicksky, JMM uses keyword DATE in the form YYYY-MM-DD. I can create that from DATE-OBS
$FAKV $fname DATE STRING `$FGKV $fname DATE-OBS STRING | sed 's/T.*//'`




######################################
# What to do if enclosure is closed

ENC_CLOSED:

exit 0
 

