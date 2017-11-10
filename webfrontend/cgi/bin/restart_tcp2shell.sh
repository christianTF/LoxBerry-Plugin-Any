#!/bin/bash

loxberryhome=REPLACEINSTALLFOLDER
pluginname=REPLACEFOLDERNAME
PIDFILES=/run/shm/tcp2shell.*

# Directory/Pluginname fallback for test environment
if [ ! -d $loxberryhome ]; then
	loxberryhome=/opt/loxberry
fi
if [ ! -d $pluginname ]; then
	pluginname=anyplugin
fi

# Stop running processes
# if [ -e  $PIDFILES ] 
# then
	# for file in $PIDFILES
	# do
		# extension="${file##*.}"
		# echo "Processing PID $extension"
		# /bin/kill -SIGTERM $extension
	# done
# fi

echo "Running killall..."
sudo killall -e tcp2shell2.pl

echo "Cleanup remaining pidfiles"
rm -f $PIDFILES

# Config file parsing (based on http://stackoverflow.com/a/20815951/3466839)
configfile="$loxberryhome/config/plugins/$pluginname/anyplugin.cfg" # set the actual path name of your (DOS or Unix) config file
if [ -e $configfile ]; then
  mkdir /run/shm/$pluginname > /dev/null 2>&1
  chown loxberry.loxberry /run/shm/$pluginname > /dev/null 2>&1
  chmod a+w /run/shm/$pluginname > /dev/null 2>&1
  shopt -s extglob
  tr -d '\r' < $configfile > /run/shm/$pluginname/tempconfigfile.unix
  while IFS='= ' read lhs rhs
  do
      if [[ ! $lhs =~ ^\ *# && -n $lhs ]]; then
          rhs="${rhs%%\#*}"    # Del in line right comments
          rhs="${rhs%%*( )}"   # Del trailing spaces
          rhs="${rhs%\"*}"     # Del opening string quotes
          rhs="${rhs#\"*}"     # Del closing string quotes
          if [[ $lhs =~ ^\[ ]]; then # Set INI-like sections, e.g. [MAIN]
            lhs="${lhs%\]*}"     # Del opening bracket
            lhs="${lhs#\[*}"     # Del closing bracket
            sec=$lhs
          else
            if [[ ! $lhs =~ ^\; ]]; then # Don't parse comments startet with ;
              name="$sec$lhs"
              declare ${name}="$rhs"
              #echo "$name = $rhs" # for debugging only
            fi
          fi
      fi
  done < /run/shm/$pluginname/tempconfigfile.unix
  rm /run/shm/$pluginname/tempconfigfile.unix > /dev/null 2>&1
  # Config file parsing end
fi

# If runas is empty, set loxberry as user
if [ -z "$Mainrunas" ]; then
	Mainrunas = "root"
fi

if [ $Mainactivated == 1 ]; then
	echo "$pluginname activated. Running command..."
	sudo -n -u $Mainrunas -- $loxberryhome/webfrontend/cgi/plugins/$pluginname/bin/tcp2shell2.pl &
	# $loxberryhome/webfrontend/cgi/plugins/$pluginname/bin/tcp2shell2.pl & 1> /dev/null 2> $loxberryhome/log/plugins/$pluginname/tcp2shell.log
fi
