#!/bin/tcsh
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
set LOGFILE = /icc/log/${hostname}.log

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
 
