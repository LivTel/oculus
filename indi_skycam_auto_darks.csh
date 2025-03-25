#!/bin/tcsh

# This is almost a clone of the indi_skycam.csh script, but for darks
#
# invoke with
#       indi_auto_darks.csh /usr/local/etc/indi_skycam_newskycam.cfg
#	OR
#       indi_auto_darks.csh /usr/local/etc/indi_skycamz_zwo_asi174mm.cfg


# Source the setup script.
# Using the same setup between this and the exposure script guarantees both are using the same settings. 
source /usr/local/bin/indi_skycam_setup.csh
set procname = indi_skycam_auto_darks.csh

if ($DEBUG) echo `datestamp` $hostname ${procname}: Proceed to checking dome >> $LOGFILE


################################
# Only run if the dome is closed
################################

# $FORCE_TELDATA allows us to totally ignore the http://192.168.4.1/teldata system.
# E.g., for testing the camera off-site
# ($FORCE_TELDATA == 0) is the normal state. It would only ever be set 'ON' in rare diagnostic tests. 
# Never run that way on sky.

if ($FORCE_TELDATA) then
  echo "FORCE_TELDATA is set. Will not even try to get http://192.168.4.1/teldata" >> $LOGFILE
else
  # http://192.168.4.1/teldata takes several seconds to be generated, so we need to make sure we have not
  # collected a half written version. If we have then we just try again. The loopct is here so that 
  # we do not get into an infinite loop of the http://192.168.4.1/teldata system fails. We will give up 
  # after five attempts.
  set loopct = 0
  while ( $loopct < 5 ) 
    if ($DEBUG) then
      wget --timeout 5 http://192.168.4.1/teldata -O /tmp/teldata >>& $LOGFILE
    else 
      wget --timeout 5 http://192.168.4.1/teldata -O /tmp/teldata >>& /dev/null
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
endif

# Check if either dome is open or the --forcedome option was set
if ($FORCE_DOME) then
  if ($DEBUG) echo `datestamp` $hostname ${procname}: "Enclosure ignored by --forcedome option" >> $LOGFILE
else
  if (!(-z /tmp/enclosure-open)) then
    if ($DEBUG) echo `datestamp` $hostname ${procname}: "enclosure open" >> $LOGFILE
    goto ENC_OPEN
  endif
  if ($DEBUG) echo `datestamp` $hostname ${procname}: "enclosure closed" >> $LOGFILE
endif





# delete old temporary output file if there is one
rm -f "${datadir}/${inst_letter}_IMAGE_"*.fits >& /dev/null


# Params for darks set here. Not using the values form the config file.
set MULTRUN = 5
set OVERHEAD = 3

# This gives us
#   20,15,10,5 to fit against and derive the mean bias level
#   a whole load of 10sec we can stack
#   See wiki page for analysis of the 20 15 10 5 sets. Now we just want plenty of 10sec to actually use.
#foreach EXPTIME (20 15 10 5 10 10 10 10)
foreach EXPTIME (10 10 10)


  echo Start $MULTRUN x $EXPTIME >> $LOGFILE

  # Take a $MULTRUN x $EXPTIME multrun
  set ct = 0
  while($ct < $MULTRUN)

    set lmst = ` $LMST `
    if ($DEBUG) echo `datestamp` $hostname ${procname}:  LMST $lmst >> $LOGFILE
    set ccdatemp = `indi_getprop -1 -p 7264 "${HARDWARE_NAME}.CCD_TEMPERATURE.CCD_TEMPERATURE_VALUE"`
    if ($DEBUG) echo `datestamp` $hostname ${procname}:  CCDATEMP $ccdatemp >> $LOGFILE

    if ($DEBUG) echo `datestamp` $hostname ${procname}:  Start $EXPTIME sec exposure >> $LOGFILE
    indi_setprop -p 7264 "${HARDWARE_NAME}.CCD_EXPOSURE.CCD_EXPOSURE_VALUE=${EXPTIME}"
    sleep $OVERHEAD
    @ ct++
    # Parse return value from CCD_EXPOSURE.CCD_EXPOSURE_VALUE as a string, not as a number.
    while ( `indi_getprop -1 -p 7264 "${HARDWARE_NAME}.CCD_EXPOSURE.CCD_EXPOSURE_VALUE"` != "0" )
      if ($DEBUG) printf "remaining %s sec\n" `indi_getprop -1 -p 7264 "${HARDWARE_NAME}.CCD_EXPOSURE.CCD_EXPOSURE_VALUE"` >> $LOGFILE
      #if ($DEBUG) printf "."  >> $LOGFILE
      sleep 1
    end
    if ($DEBUG) printf "\n"  >> $LOGFILE

    # generate LT style standard filename and rename/move temporary image
    # In fact indiserver is capable of doing this itself now. See note in UPLOAD configs above.
    set fname = ` $FILENAME DARK $inst_letter $datadir `
    if ($DEBUG) echo `datestamp` $hostname ${procname}:  File name will be $fname >> $LOGFILE

    if (! -e ${datadir}/${inst_letter}_IMAGE_001.fits ) then
      echo `datestamp` $hostname ${procname}: "ERROR : No output image (${datadir}/${inst_letter}_IMAGE_001.fits) from indiserver" >> $LOGFILE

      # Disconnect from the server. That will force the script to reconnect and attempt to reinitialise everything next time
      echo `datestamp` $hostname ${procname}: " Disconnect from indiserver" >> $LOGFILE
      indi_setprop -p 7264 "${HARDWARE_NAME}.CONNECTION.DISCONNECT=On"
      sleep 3
      indi_getprop -p 7264 "${HARDWARE_NAME}.CONNECTION.CONNECT" >> $LOGFILE

      exit 1
    else

      mv "${datadir}/${inst_letter}_IMAGE_001.fits" $fname

      if ($DEBUG) echo `datestamp` $hostname ${procname}: Update all the FITS headers in $fname >> $LOGFILE
      # Add LST to the FITS header. This is LST just before the oculus code was called, not the moment the shutter opened
      $FAKV $fname LST STRING "${lmst}"

      # Transcribe existing FITS keywords into our standard LT versions
      $FAKV $fname UTSTART STRING `$FGKV $fname DATE-OBS STRING `
      $FAKV $fname CCDXBIN INT `$FGKV $fname XBINNING INT `
      $FAKV $fname CCDYBIN INT `$FGKV $fname YBINNING INT `
      $FAKVC $fname CCDXPIXE DOUBLE `$FGKV $fname PIXSIZE1 DOUBLE ` "um" "Physical pixel size"
      $FAKVC $fname CCDYPIXE DOUBLE `$FGKV $fname PIXSIZE2 DOUBLE ` "um" "Physical pixel size"

      # In quicksky, JMM uses keyword DATE in the form YYYY-MM-DD. I can create that from DATE-OBS
      $FAKV $fname DATE STRING `$FGKV $fname DATE-OBS STRING | sed 's/T.*//'`

      $FAKVC $fname CCDATEMP DOUBLE $ccdatemp "C" "Detector temperature"

      if ($DEBUG) echo `datestamp` $hostname ${procname}: Success. >> $LOGFILE
    endif

  end

end


######################################
# What to do if enclosure is open

ENC_OPEN:

if ($DEBUG) echo `datestamp` $hostname ${procname}: Exit script. >> $LOGFILE
exit 0

