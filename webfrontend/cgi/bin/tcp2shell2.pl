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
our $version = LoxBerry::System::pluginversion();

# Christian Fenzl, christiantf@gmx.at 2017-2018
# This script is a TCP to Shell gateway. 

# Debian Packages required
# - libswitch-perl
# - libio-socket-timeout-perl

##########################################################################
# Modules
##########################################################################

use Basics;
use strict;
use warnings;


# use FindBin;
# use lib "$FindBin::RealBin/../perllib";

use Config::Simple;
use Cwd 'abs_path';
use File::HomeDir;
use Getopt::Long qw(GetOptions);
use HTML::Entities;
use Net::Subnet;
use IO::Select;
use IO::Socket;
use IO::Socket::Timeout;
use IO::Socket::IP;
use IO::Interface qw(:flags);
# use IO::Interface;
use List::Util 1.33 'any';
use LWP::UserAgent;
use POSIX qw/ strftime /;
use Switch;
use Time::HiRes qw(usleep);
use URI::Escape;
# use TCPUDP;


print STDERR "###################### Any-Plugin V$version ######################\n";
print STDERR "Global variables from LoxBerry::System\n";
print STDERR "Homedir:     $lbhomedir\n";
print STDERR "Plugindir:   $lbplugindir\n";
print STDERR "YOUR commands:      $lbdatadir/commands\n";
#print STDERR "HTMLdir:     $lbhtmldir\n";
#print STDERR "Templatedir: $lbtemplatedir\n";
#print STDERR "Datadir:     $lbdatadir\n";
#print STDERR "Logdir:      $lblogdir\n";
#print STDERR "Configdir:   $lbconfigdir\n";


my $home = $lbhomedir;
our $tcpin_sock;
our $tcpout_sock;
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
# my $security = defined $cfg->param("Main.security_mode") ? uc $cfg->param("Main.security_mode") : uc "restricted";
my $security = "UNSECURE";
my $authentication = !is_enabled($cfg->param("Main.authentication")) ? 0 : 1;
my $restrict_subnet = is_enabled($cfg->param("Main.restrict_subnet")) ? 1 : 0;
my @restricted_ips = $cfg->param("Main.allowed_remote_ips");
# print "Restricted IPs (" . scalar(@restricted_ips ) ."): " . join(", ", @restricted_ips);
@restricted_ips = grep /\S/, @restricted_ips;
print STDERR "Restricted IPs (" . scalar(@restricted_ips ) ."): " . join(", ", @restricted_ips) . "\n";




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

sleep 2;

# Create sockets
## Listen to a guest TCP connection
$tcpin_sock = create_in_socket($tcpin_sock, $tcpin_port, 'tcp');
$in_list = IO::Select->new ($tcpin_sock);


our @udpout_sock;
my @udpout_host;
my @udpout_port;

# Create UDP socket for each Miniserver
for (my $msnrs = 1 ; $msnrs <= keys %miniservers; $msnrs++) {

	$udpout_host[$msnrs] = $miniservers{$msnrs}{IPAddress};
	$udpout_port[$msnrs] = $udpport;

	# Create a guest UDP stream
	$udpout_sock[$msnrs] = create_out_socket($udpout_sock[$msnrs], $udpout_port[$msnrs], 'udp', $udpout_host[$msnrs]);
	$udpout_sock[$msnrs]->flush;

}


# Now we are ready to listen and process
our $answer; 
our $guest;
my $lastpoll = time;
# my $msnr;
					
start_listening();

	close $tcpout_sock;
	# close $udpout_sock;
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
	
	# Determine own IP and subnets
	
	while (1)
	{
		
		# Quit finished child processes
		my $procchild;
		do {
			$procchild = waitpid(-1, 1);
		} while $procchild > 0;
		
		# This is the handling of incoming TCP connections (Guests)
		###########################################################
		
		
		if (my @in_ready = $in_list->can_read(0.2)) {
			foreach $guest (@in_ready) {
				if($guest == $tcpin_sock) {
					# Create new incoming connection from guest
					my $new = $tcpin_sock->accept  or die "ERROR: It seems that this port is already occupied - Another instance running?\nQUITTING with error: $! ($@)\n";
					
					## Check restrictions
					my $newremote = $new->peerhost();
					(my $sec, my $min, my $hour, my $mday, my $mon, my $year, my $wday, my $yday, my $isdst) = localtime();
					my $currtime = sprintf "####### New Connection ### $year-$mon-$mday $hour:$min:$sec LOCAL TIME ###### \n";
					print STDERR $currtime;
					print STDERR "Remote: " . $newremote . "\n";
					
					if ($restrict_subnet && !own_subnet($new, $newremote)) {
						print STDERR "ERROR - Access denied. Quitting.\n";
						close $new;
					} elsif (@restricted_ips && !any { /$newremote/ } @restricted_ips ) {
						print STDERR "ERROR - Access denied. Quitting.\n";
						close $new;
					} else {
						print STDERR "New guest connection accepted from $newremote.\n";
						$in_list->add($new);
					}
					
				} else {
					$guest->recv(my $guest_line, 1024);
					my $guest_answer;
					# my $msnr;
					chomp $guest_line;
					print STDERR "GUEST: $guest_line\n";
					my @guest_params = split(/ /, $guest_line);
					# print "GUEST_PARAMS[0]: $guest_params[0] \n";
					
					## Get first parameter (<Name> or keyword)
					my $rname_temp = $guest_params[0];
					my $rname;
					switch(lc $rname_temp) {
						case 'status' {	print STDERR "1. Parameter is STATUS\n"; }
						else		  { print STDERR "1. Parameter (Name) is $rname_temp\n"; 
										$rname = $rname_temp;}
					}

					## Get second parameter (return method)
					my ($rreturn, $msnr) = split /\./, lc $guest_params[1], 2;
					
					switch ($rreturn) {
						case 'off'	{ print STDERR "2. Parameter is off (nothing will be returned)\n"; }
						case 'rc'	{ print STDERR "2. Parameter is rc (will return exit code)\n"; }
						case 'udp'	{ print STDERR "2. Parameter is udp (will return udp string)\n"; }
						case 'rcudp'{ print STDERR "2. Parameter is rcudp (will return exit code and udp string)\n"; }
						else		{ print STDERR "2. Parameter undefined - set to rc\n";
											$rreturn = "off";
										}
							}
					
					## Get third parameter (command or macro)
					my $rcommand = lc $guest_params[2]; 
					switch ($rcommand) {
						case 'command'	{ print STDERR "3. Parameter is command (will run following command)\n"; }
						case 'macro'	{ print STDERR "3. Parameter is macro (will run macro $guest_params[3])\n"; }
						case 'ping'		{ print STDERR "3. Parameter is ping (will return Linux epoch time)\n"; }
						else			{ print STDERR "3. Parameter is undefined - QUITTING guest\n";
											$rcommand = undef;}
					}
				
					## Check the Miniserver number
					if (! defined $msnr) { 
						print STDERR "No MS defined. Setting to msnr=1\n";
						$msnr = 1; 
					}
					if ($msnr < 1 or $msnr gt keys %miniservers)
						{ print STDERR "ERROR: Given number of Miniserver ($msnr) does not exist - QUITTING guest\n";
						  $rname = undef;
						  $msnr = undef;
					}
					
					if (defined $msnr and $msnr gt 0) { print STDERR "Miniserver used is $msnr (" . $miniservers{$msnr}{Name} . ")\n";}
					
					## Decide what to do next
					if (defined $rname) {
						if ( $rcommand eq "command" ) 
							{ print STDERR "Calling exec_command\n";
							  exec_command($rname, $rreturn, $msnr, @guest_params);
							}
						elsif ( $rcommand eq "macro" )
							{ print STDERR "Calling exec_macro $guest_params[3]\n";
							  exec_macro($rname, $rreturn, $msnr, $guest_params[3]);
							}
						elsif ( $rcommand eq "ping" )
							{ print STDERR "Calling ping\n";
							  exec_ping($rname, $rreturn, $msnr);
							}
						
						
					} else { print STDERR "Doing nothing, client good bye!\n"; }
					
					if ($guest->connected) {
						print $guest "$guest_line received. Good bye.\n";
					}
					
					$msnr = undef;
					$guest_line = undef;
					$in_list->remove($guest);
					$guest->close;
					
					
					
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
	my ($rname, $rreturn, $msnr, @rline) = @_;
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
	
	executeCommandline($rname, $rreturn, $msnr, $commandline);
	
}


#####################################################################################

sub exec_ping
{
	my ($rname, $rreturn, $msnumber) = @_;
	
	# Send epoch as Return Code
  if (substr ($rreturn, 0, 2) eq 'rc' || substr ($rreturn, 0, 5) eq 'rcudp') {
	to_ms($rname, time, $msnumber);
  }
  # Send epoch by UDP
  if (substr ($rreturn, 0, 3) eq 'udp' || substr ($rreturn, 0, 5) eq 'rcudp') {
	my $udp_output = 
		"\"$rname\":" . time;
	$udp_output = substr $udp_output, 0, 255;
	my $udp_out = $udpout_sock[$msnumber];
	print STDERR "SEND via UDP to MS$msnumber: $udp_output\n";
	print $udp_out $udp_output;
  }
	
}


#################################################################################
# Run Commandline in shell
# Params: $rname, $rreturn, $msnr, $commandline
# Returns: -
#################################################################################

sub executeCommandline
{
  my ($rname, $rreturn, $msnumber, $commandline) = @_;
  my $output;
  my $status;
  
  print STDERR "Try to fork\n";
  my $pid = fork();
  if (not defined $pid) {
		print STDERR "!!! Could not fork.\n";
  }
  if (not $pid) {
		print STDERR "Command forked.\n";
  
		  ($output, $status) = executeShell($commandline);
		  
		  print STDERR "Exit Code: $status\n";
		  print STDERR "Output:\n";
		  print STDERR $output . "\n";
		  
		  # print STDERR "Name is $rname, return mode is $rreturn\n";
		  
		  # Send Return Code
		  if (substr ($rreturn, 0, 2) eq 'rc' || substr ($rreturn, 0, 5) eq 'rcudp') {
			to_ms($rname, $status, $msnumber);
		  }
		  # Send Output by UDP
		  if (substr ($rreturn, 0, 3) eq 'udp' || substr ($rreturn, 0, 5) eq 'rcudp') {
			my $udp_output = 
				"\"$rname\":" . 
				"$output";
			$udp_output = substr $udp_output, 0, 255;
			my $udp_out = $udpout_sock[$msnumber];
			print $udp_out $udp_output;
			print STDERR "SEND via UDP to MS$msnumber: $udp_output\n";
			
		  }
		exit(0);
		}
}

# Runs the shell command and returns output and status code
sub executeShell {
  my ($commandline) = @_;
  
  my $output = qx{cd $lbdatadir/commands; $commandline 2>&1};
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
	sleep (1.5);
	if ($socket->connected) {
		print STDERR "Created $proto out socket to $remotehost on port $port\n";
	} else {
		print STDERR "WARNING: Socket to $remotehost on port $port seems to be offline - will retry\n";
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
	die "cannot create socket - Already in use?\nERROR is: $!\n" unless $socket;
	# In some OS blocking mode must be expricitely disabled
	IO::Handle::blocking($socket, 0);
	print STDERR "server waiting for $proto client connection on port $port\n";
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
	
	my ($label, $text, $msnumber) = @_;
	
	$msnumber = defined $msnumber ? $msnumber : 1;
	
	# if (! $lms2udp_usehttpfortext) { return; }
	
	#my $playeridenc = uri_escape( $playerid );
	#my $labelenc = uri_escape ( $label );
	my $textenc = uri_escape( $text );
	
	my $labelenc = uri_escape( $label );
	
	
	my $url = "http://" . $miniservers{$msnumber}{Credentials} . "@" . $miniservers{$msnumber}{IPAddress} . ":" . $miniservers{$msnumber}{Port} . "/dev/sps/io/$labelenc/$textenc";
	my $url_nopass = "http:// " . $miniservers{$msnumber}{Admin} . ":*****\@" . $miniservers{$msnumber}{IPAddress} . ":" . $miniservers{$msnumber}{Port} . "/dev/sps/io/$labelenc/$textenc";
	my $ua = LWP::UserAgent->new;
	$ua->timeout(1);
	print STDERR "DEBUG: #$label# #$text#\n";
	print STDERR "SEND via HTTP-REST to MS$msnumber: -->URL $url_nopass\n";
	my $response = $ua->get($url);
	return $response;
}

#####################################################
# Check if remote host is in own subnet
# Input: Socket, Remote IP
# Output: 1/0 (true/false)
#####################################################
sub own_subnet
{
	my ($socket, $remoteadr) = @_;
	my @subnets;
	my @interfaces = $socket->if_list;
	
	foreach my $iface (@interfaces) {
		#if (!$$socket->is_loopback($iface)) {
		#	print $iface . "\n " . 
		#	"addr = 	" . $socket->if_addr($iface) . "\n" .
		#	"mask=		" . $socket->if_netmask($iface) . "\n";
			push @subnets, $socket->if_addr($iface) . "/" . $socket->if_netmask($iface);
		#}
	}
	# print "Subnets: " . join(", ", @subnets) . "\n";
	my $is_rfc1918 = subnet_matcher @subnets;
	my $isownsubnet = $is_rfc1918->($remoteadr);
	# my $isownsubnet = $is_rfc1918->('192.168.1.222');
	# print "$remoteadr is own subnet: " . $isownsubnet . "\n";
	return $isownsubnet;
	
}
