#!/usr/bin/perl

if (-d "REPLACEINSTALLFOLDER/webfrontend/cgi/plugins/anyplugin/perllib") {
	use lib 'REPLACEINSTALLFOLDER/webfrontend/cgi/plugins/anyplugin/perllib';
} else {
	use lib "/opt/loxberry/webfrontend/cgi/plugins/anyplugin/perllib";
}

use LoxBerry::System;
use LoxBerry::Web;


if (-d "REPLACEINSTALLFOLDER/webfrontend/cgi/plugins/anyplugin/lib") {
	use lib 'REPLACEINSTALLFOLDER/webfrontend/cgi/plugins/anyplugin/lib';
} else {
	use lib '/opt/loxberry/webfrontend/cgi/plugins/anyplugin/lib';
}

# Version of this script
our $version = "0.01";

# Christian Fenzl, christiantf@gmx.at 2017
# This script is a TCP to Shell gateway. 

# Debian Packages required
# - libswitch-perl
# - libio-socket-timeout-perl

use Basics;
use strict;
use warnings;

##########################################################################
# Modules
##########################################################################

# use FindBin;
# use lib "$FindBin::RealBin/../perllib";

use Config::Simple;
use Cwd 'abs_path';
use File::HomeDir;
use Getopt::Long qw(GetOptions);
use HTML::Entities;
use IO::Select;
#use IO::Socket;
use IO::Socket::Timeout;
use IO::Socket::IP;

use LWP::UserAgent;
use POSIX qw/ strftime /;
use Switch;
use Time::HiRes qw(usleep);
use URI::Escape;
# use TCPUDP;

print STDERR "Global variables from LoxBerry::System\n";
print STDERR "Homedir:     $lbhomedir\n";
print STDERR "Plugindir:   $lbplugindir\n";
print STDERR "CGIdir:      $lbcgidir\n";
print STDERR "HTMLdir:     $lbhtmldir\n";
print STDERR "Templatedir: $lbtemplatedir\n";
print STDERR "Datadir:     $lbdatadir\n";
print STDERR "Logdir:      $lblogdir\n";
print STDERR "Configdir:   $lbconfigdir\n";


my $home = $lbhomedir;
our $tcpin_sock;
our $tcpout_sock;
our $udpout_sock;
our $in_list;
our $out_list;
my $sel;
my $client;
my $guest_line;

our $line;

# Creating pid
my $pidfile = "/run/shm/tcp2shell.$$";
open(my $fh, '>', $pidfile);
print $fh "$$";
close $fh;

# For debugging purposes, allow option --activate to override disabled setting in the config
my $option_activate;
GetOptions('activate' => \$option_activate) or die "Usage: $0 --activate to override config unactivate\n";

# Load Configuration from config file
# Read plugin settings
my $cfgfilename = "$lbconfigdir/$lbplugindir.cfg";
# tolog("INFORMATION", "Reading Plugin config $cfg");
if (! (-e $cfgfilename)) {
	print STDERR "Any-Plugin configuration file does not exist. Terminating.\n";
	unlink $pidfile;
	exit(0);
}

# Read the Plugin config file 
our $cfg = new Config::Simple($cfgfilename);

my $activated = $cfg->param("Main.activated");
our $cfgversion = $cfg->param("Main.ConfigVersion");
my $udpport = $cfg->param("Main.udpport");
my $tcpport = $cfg->param("Main.tcpport");
my $security = defined $cfg->param("Main.security_mode") ? uc $cfg->param("Main.security_mode") : uc "restricted";
my $authentication = !is_enabled($cfg->param("Main.authentication")) ? 0 : 1;


if(! is_true($activated) && ! $option_activate) {	
	print STDERR "Any-Plugin is NOT activated in config file. That's ok. Terminating.\n";
	unlink $pidfile;
	exit(0);
}

print STDERR "Any-Plugin mode is $security\n";

# Init default values if empty
if (! $tcpport) { $tcpport = 9095; }
if (! $udpport) { $udpport = 9096; }

# Miniserver data
our %miniservers = LoxBerry::System::get_miniservers();

# This ist the host we are mirroring commands to the remote machine. Incoming commands from Loxone are mirrored to the remote machine.
my $tcpin_port = $tcpport;
# This is the host we mirror the TCP incoming messages to (usually the Miniserver)
my $udpout_host = $miniservers{1}{IPAddress};
my $udpout_port = $udpport;

# Create sockets
## Listen to a guest TCP connection
$tcpin_sock = create_in_socket($tcpin_sock, $tcpin_port, 'tcp');
$in_list = IO::Select->new ($tcpin_sock);

# Create a guest UDP stream
$udpout_sock = create_out_socket($udpout_sock, $udpout_port, 'udp', $udpout_host);
$udpout_sock->flush;

our $answer; 


# Now we are ready to listen and process

our $guest;
my $lastpoll = time;

start_listening();

	close $tcpout_sock;
	close $udpout_sock;
	close $tcpin_sock;
# and terminate the connection when we're done

END 
{
	# Delete pid file
	if (-e "$pidfile") {
		unlink "$pidfile";
	}
}		


#################################################################################
# Listening sub
# Params: none
# Returns: none
#################################################################################

sub start_listening 
{
	while (1)
	{
		# This is the handling of incoming TCP connections (Guests)
		###########################################################
		if (my @in_ready = $in_list->can_read(0.2)) {
			foreach $guest (@in_ready) {
				if($guest == $tcpin_sock) {
					# Create new incoming connection from guest
					my $new = $tcpin_sock->accept;
					$in_list->add($new);
					print "New guest connection accepted\n";
				} else {
					$guest->recv(my $guest_line, 1024);
					my $guest_answer;
					chomp $guest_line;
					print "GUEST: $guest_line\n";
					my @guest_params = split(/ /, $guest_line);
					print "GUEST_PARAMS[0]: $guest_params[0] \n";
					
					## Get first parameter (<Name> or keyword)
					my $rname_temp = $guest_params[0];
					my $rname;
					switch(lc $rname_temp) {
						case 'status' {	print "1. Parameter is STATUS\n"; }
						else		  { print "1. Parameter (Name) is $rname_temp\n"; 
										$rname = $rname_temp;}
					}

					## Get second parameter (return method)
					my $rreturn = lc $guest_params[1];
					switch ($rreturn) {
						case 'off'	{ print "2. Parameter is off (nothing will be returned)\n"; }
						case 'rc'	{ print "2. Parameter is rc (will return exit code)\n"; }
						case 'udp'	{ print "2. Parameter is udp (will return udp string)\n"; }
						case 'rcudp'{ print "2. Parameter is rcudp (will return exit code and udp string)\n"; }
						else		{ print "2. Parameter undefined - set to rc\n";
											$rreturn = "off";
										}
							}
					
					## Get third parameter (command or macro)
					my $rcommand = lc $guest_params[2]; 
					switch ($rcommand) {
						case 'command'	{ print "3. Parameter is command (will run following command)\n"; }
						case 'macro'	{ print "3. Parameter is macro (will run macro $guest_params[3])\n"; }
						else			{ print "3. Parameter is undefined - QUITTING guest\n";
											$rcommand = undef;}
					}
				
					## Decide what to do next
					if (defined $rname) {
						if ( $rcommand eq "command" ) 
							{ print STDERR "Calling exec_command\n";
							  exec_command($rname, $rreturn, @guest_params);
							}
						elsif ( $rcommand eq "macro" )
							{ print STDERR "Calling exec_macro $guest_params[3]\n";
							  exec_macro($rname, $rreturn, $guest_params[3]);
							}
						
					} else { print STDERR "Doing nothing, client good bye!\n"; }
					
					$in_list->remove($guest);
					$guest->close;
					$guest_line = undef;
					
				}
			}
		}
	}
}

#####################################################################################
## Here are routines for guest requests
#####################################################################################

#####################################################################################

sub exec_command
{
	my $commandline;
	my ($rname, $rreturn, @rline) = @_;
	splice @rline, 0, 3;
	
	if ($security ne "UNSECURE") {
		print STDERR "NOT ALLOWED without UNSECURE mode. Quitting.\n";
		return -1;
	}

	for (my $nr=0; $nr < (scalar @rline); $nr++) {
		$commandline .= $rline[$nr] . " ";
	}
	rtrim($commandline);
	print STDERR "exec_command Commandline: $commandline\n";
	
	executeCommandline($rname, $rreturn, $commandline);
	
}

#################################################################################
# Run Commandline in shell
# Params: $rname, $rreturn, $commandline
# Returns: -
#################################################################################

sub executeCommandline
{
  my ($rname, $rreturn, $commandline) = @_;
  my $output;
  my $status;
  
  ($output, $status) = executeShell($commandline);
  
  print STDERR "Exit Code: $status\n";
  print STDERR "Output:\n";
  print STDERR $output;
  
  # print STDERR "Name is $rname, return mode is $rreturn\n";
  
  # Send Return Code
  if ($rreturn eq "rc" || $rreturn eq "rcudp") {
	to_ms($rname, $status);
  }
  # Send Output by UDP
  if ($rreturn eq "udp" || $rreturn eq "rcudp") {
	my $udp_output = 
		"\"$rname\":" . 
		"$output";
	$udp_output = substr $udp_output, 0, 255;
	print $udpout_sock $udp_output;
  }
  
}

# Runs the shell command and returns output and status code
sub executeShell {
  my ($commandline) = @_;
  
  my $output = qx{$commandline 2>&1};
  my $status = $? >> 8;
  # Negative exit code is returned as 16bit int --> correct this 
  $status = ($status & 0x80) ? -(0x100 - ($status & 0xFF)) : $status;
  
  ($_ = $output, $status);
  #($_ = qx{$commandline 2>&1}, $? >> 8);
}


#################################################################################
# Create Out Socket
# Params: $socket, $port, $proto (tcp, udp), $remotehost
# Returns: $socket
#################################################################################

sub create_out_socket 
{
	my ($socket, $port, $proto, $remotehost) = @_;
	
	my %params = (
		PeerHost  => $remotehost,
		PeerPort  => $port,
		Proto     => $proto,
		Blocking  => 0
	);
	
	if ($proto eq 'tcp') {
		$params{'Type'} = SOCK_STREAM;
	} elsif ($proto eq 'udp') {
		# $params{'LocalAddr'} = 'localhost';
	}
	if($socket) {
		close($socket);
	}
		
	$socket = IO::Socket::IP->new( %params )
		or die "Couldn't connect to $remotehost:$port : $@\n";
	sleep (1);
	if ($socket->connected) {
		print "Created $proto out socket to $remotehost on port $port\n";
	} else {
		print "WARNING: Socket to $remotehost on port $port seems to be offline - will retry\n";
	}
	IO::Socket::Timeout->enable_timeouts_on($socket);
	$socket->read_timeout(2);
	$socket->write_timeout(2);
	return $socket;
}

#################################################################################
# Create In Socket
# Params: $socket, $port, $proto (tcp, udp)
# Returns: $socket
#################################################################################

sub create_in_socket 
{

	my ($socket, $port, $proto) = @_;
	
	my %params = (
		LocalHost  => '0.0.0.0',
		LocalPort  => $port,
		Type       => SOCK_STREAM,
		Proto      => $proto,
		Listen     => 5,
		Reuse      => 1,
		Blocking   => 0
	);
	$socket = new IO::Socket::IP ( %params );
	die "cannot create socket $!\n" unless $socket;
	# In some OS blocking mode must be expricitely disabled
	IO::Handle::blocking($socket, 0);
	print "server waiting for $proto client connection on port $port\n";
	return $socket;
}

#####################################################
# Miniserver REST Calls for Strings
# Uses globals
# Used for 
#	- Title
#	- Mode
#	- Player name
#####################################################
sub to_ms 
{
	
	my ($label, $text) = @_;
	
	# if (! $lms2udp_usehttpfortext) { return; }
	
	#my $playeridenc = uri_escape( $playerid );
	#my $labelenc = uri_escape ( $label );
	my $textenc = uri_escape( $text );
	
	my $labelenc = uri_escape( $label );
	
	
	my $url = "http://" . $miniservers{1}{Credentials} . "@" . $miniservers{1}{IPAddress} . ":" . $miniservers{1}{Port} . "/dev/sps/io/$labelenc/$textenc";
	my $url_nopass = "http:// " . $miniservers{1}{Admin} . ":*****\@" . $miniservers{1}{IPAddress} . ":" . $miniservers{1}{Port} . "/dev/sps/io/$labelenc/$textenc";
	my $ua = LWP::UserAgent->new;
	$ua->timeout(1);
	print "DEBUG: #$label# #$text#\n";
	print "DEBUG: -->URL $url_nopass\n";
	my $response = $ua->get($url);
	return $response;
}
