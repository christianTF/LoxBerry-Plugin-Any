#!/usr/bin/perl

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


##########################################################################
# Modules
##########################################################################
use FindBin;
use lib "$FindBin::Bin/./perllib";
use LoxBerry::System;
use LoxBerry::Web;

# Version of this script
our $version = LoxBerry::System::pluginversion();

use Switch;
use CGI::Carp qw(fatalsToBrowser);
use CGI qw/:standard/;
use Config::Simple;
use HTML::Template;
use Scalar::Util qw( looks_like_number );
use warnings;
use strict;
no strict "refs"; # we need it for template system and for contructs like ${"skalar".$i} in loops

# For debug purposes
use Data::Dumper;


##########################################################################
# Variables
##########################################################################
our  $cgi = CGI->new;
my  $pcfg;
my  $lang;
my  $languagefile;
my  $pname;
my  $languagefileplugin;
my  %TPhrases;
my $topmenutemplate;
my $maintemplate;
my $footertemplate;

my $dd_schedule;
my $dd_retention;
my $rsync_schedule;
my $rsync_retention;
my $tgz_schedule;
my $tgz_retention;
my $stop_services;
my $par_stopservices;
my $par_startservices;
my $mail_params;
our $errormsg;

my $dd_backup_command;
my $tgz_backup_command;
my $rsync_backup_command;

our @backuptypes = ('DD', 'RSYNC', 'TGZ');

##########################################################################
# Read Settings
##########################################################################

 my $datestring = localtime();
 print STDERR "========== LoxBerry Backup Version $version === ($datestring) =========\n";
 print STDERR "Global variables from LoxBerry::System\n";
 print STDERR "Homedir:     $lbhomedir\n";
 print STDERR "Plugindir:   $lbplugindir\n";
 print STDERR "CGIdir:      $lbcgidir\n";
 print STDERR "HTMLdir:     $lbhtmldir\n";
 print STDERR "Templatedir: $lbtemplatedir\n";
 print STDERR "Datadir:     $lbdatadir\n";
 print STDERR "Logdir:      $lblogdir\n";
 print STDERR "Configdir:   $lbconfigdir\n";

# Start with HTML header
print $cgi->header(
         -type    =>      'text/html',
         -charset =>      'utf-8'
);

# Get language from GET, POST or System setting (from LoxBerry::Web)
$lang = lblanguage();

##########################################################################
# Read and process config
##########################################################################

# Read plugin config 
# $pcfg 	= new Config::Simple("$lbconfigdir/anyplugin.cfg");
# if (! defined $pcfg) {
	# $pcfg = new Config::Simple(syntax=>'ini');
	# $pcfg->param("CONFIG.VERSION", $version);
	# $pcfg->write("$lbconfigdir/anyplugin.cfg");
	# $pcfg = new Config::Simple("$lbconfigdir/anyplugin.cfg");
# }
# Config::Simple->import_from('app.ini', \%Config);

my %pcfg;
tie %pcfg, "Config::Simple", "$lbconfigdir/anyplugin.cfg";

# Set default parameters
my $pcfgchanged = 0;
if (!defined $pcfg{'Main.activated'}) { $pcfg{'Main.activated'} = 1; $pcfgchanged = 1;}
if (!defined $pcfg{'Main.ConfigVersion'}) { $pcfg{'Main.ConfigVersion'} = 1; $pcfgchanged = 1;}
if (!defined $pcfg{'Main.security_mode'}) { $pcfg{'Main.security_mode'} = "unsecure"; $pcfgchanged = 1;}
if (!defined $pcfg{'Main.authentication'}) { $pcfg{'Main.authentication'} = "off"; $pcfgchanged = 1;}
if (!defined $pcfg{'Main.restrict_subnet'}) { $pcfg{'Main.restrict_subnet'} = "True"; $pcfgchanged = 1;}
if (!defined $pcfg{'Main.runas'}) { $pcfg{'Main.runas'} = "root"; $pcfgchanged = 1;}
if (!defined $pcfg{'Main.udpport'}) { $pcfg{'Main.udpport'} = "9096"; $pcfgchanged = 1;}
if (!defined $pcfg{'Main.tcpport'}) { $pcfg{'Main.tcpport'} = "9095"; $pcfgchanged = 1;}

# if ($pcfgchanged = 1) {tied(%pcfg)->write();}


##########################################################################
# Process form data
##########################################################################

if ($cgi->param("save")) {
	# Data were posted - save 
	&save;
}

##########################################################################
# Initialize html templates
##########################################################################

# See http://www.perlmonks.org/?node_id=65642

# Main
#$maintemplate = HTML::Template->new(filename => "$lbtemplatedir/multi/main.html");
$maintemplate = HTML::Template->new(
	filename => "$lbtemplatedir/multi/settings.html",
	global_vars => 1,
	loop_context_vars => 1,
	die_on_bad_params => 0,
	# associate => %pcfg,
);

# Activate Settings button in topmenu
$maintemplate->param( CLASS_INDEX => 'class="ui-btn-active ui-state-persist"');

##########################################################################
# Translations
##########################################################################

# Init Language
# Clean up lang variable
$lang         =~ tr/a-z//cd;
$lang         = substr($lang,0,2);

# Read Plugin transations
# Read English language as default
# Missing phrases in foreign language will fall back to English
$languagefileplugin 	= "$lbtemplatedir/lang/language_en.ini";
Config::Simple->import_from($languagefileplugin, \%TPhrases);

# Read foreign language if exists and not English
$languagefileplugin = "$lbtemplatedir/lang/language_$lang.ini";
# Now overwrite phrase variables with user language
if ((-e $languagefileplugin) and ($lang ne 'en')) {
	Config::Simple->import_from($languagefileplugin, \%TPhrases);
}

# Parse phrase variables to html templates
while (my ($name, $value) = each %TPhrases){
	$maintemplate->param("$name" => $value);
	#$headertemplate->param("T::$name" => $value);
	#$footertemplate->param("T::$name" => $value);
}

##########################################################################
# Create variables for the Template
##########################################################################

$maintemplate->param( PLUGINNAME => 'Any Plugin for LoxBerry' );

# Activated Checkbox
my $activated = checkbox(-name => 'activated',
								  -checked => is_enabled($pcfg{'Main.activated'}),
									-value => 'True',
									-label => $TPhrases{'SELECTIONS.CHECKBOX_ACTIVATED_PLUGIN_ACTIVATED'},
								);
$maintemplate->param( ACTIVATED => $activated);

# Textfield for TCP IN PORT
my $tcpport = textfield(-name=>'tcpport',
			   #-default=>'127.0.0.1',
			   -value=>$pcfg{'Main.tcpport'},
			   #-rows=>10,
			   #-columns=>50,
			   -size=>10,
			   -maxlength=>5,
			   );
$maintemplate->param( TCPPORT => $tcpport);

# Textfield for UDP OUT PORT
my $udpport = textfield(-name=>'udpport',
			   #-default=>'127.0.0.1',
			   -value=>$pcfg{'Main.udpport'},
			   #-rows=>10,
			   #-columns=>50,
			   -size=>10,
			   -maxlength=>5,
			   );
$maintemplate->param( UDPPORT => $udpport);

# Security_mode radio buttons
my $security_mode = radio_group(
						-name => 'security_mode',
						-values => ['unsecure', 'restricted'],
						-labels => { 
							'unsecure' => $TPhrases{'SELECTIONS.RADIO_SECURITY_MODE_UNSECURE'},
							'restricted' => $TPhrases{'SELECTIONS.RADIO_SECURITY_MODE_LIMITED'},
							},
						-default => $pcfg{'Main.security_mode'} ,
						);
$maintemplate->param( SECURITY_MODE => $security_mode);

# Activated Checkbox
my $authentication = checkbox(-name => 'authentication',
								  -checked => is_enabled($pcfg{'Main.authentication'}),
									-value => 'True',
									-label => $TPhrases{'SELECTIONS.CHECKBOX_AUTHENTICATION_ACTIVATED'},
								);
$maintemplate->param( AUTHENTICATION => $authentication);

# Restrict Subnet Checkbox
my $restrict_subnet = checkbox(-name => 'restrict_subnet',
								  -checked => is_enabled($pcfg{'Main.restrict_subnet'}),
									-value => 'True',
									-label => $TPhrases{'SELECTIONS.CHECKBOX_RESTRICT_SUBNET_ACTIVATED'},
								);
$maintemplate->param( RESTRICTED_SUBNET => $restrict_subnet);

# Textfield for allowed remote IP's
my $allowed_remote_ips = textfield(-name=>'allowed_remote_ips',
			   #-default=>'127.0.0.1',
			   -value=>$pcfg{'Main.allowed_remote_ips'},
			   #-rows=>10,
			   #-columns=>50,
			   -size=>100,
			   -maxlength=>200,
			   -label=> 'Erlaubte IP-Adressen. Leer bedeutet, alle IPs dürfen verbinden.',
			   );
$maintemplate->param( ALLOWED_REMOTE_IPS => $allowed_remote_ips);

$maintemplate->param( LBPLUGINDIR => $lbplugindir);
		
# Get currently running instances
my $runningInstances = `pgrep --exact -c tcp2shell2.pl`;
$maintemplate->param( RUNNINGINSTANCES => $runningInstances);
		
##########################################################################
# Print Template
##########################################################################

# In LoxBerry V0.2.x we use the old LoxBerry::Web header
LoxBerry::Web::lbheader("Any Plugin for LoxBerry V$version", "http://www.loxwiki.eu:80/x/7wBmAQ");

# Main
print $maintemplate->output;

# In LoxBerry V0.2.x we use the old LoxBerry::Web footer
LoxBerry::Web::lbfooter();

exit;

##########################################################################
# Save data
##########################################################################
sub save 
{

	# We import all variables to the R (=result) namespace
	$cgi->import_names('R');
	
	# now we check each imported value and write it to the config
	$pcfg{'Main.activated'} = defined $R::activated and is_enabled($R::activated) ? "1" : "0";
	$pcfg{'Main.restrict_subnet'} = defined $R::restrict_subnet and is_enabled($R::restrict_subnet) ? "true" : "false";
	$pcfg{'Main.authentication'} = defined $R::authentication and is_enabled($R::authentication) ? "on" : "off";
	
	
	if (defined $R::udpport and looks_like_number($R::udpport)) { $pcfg{'Main.udpport'} = $R::udpport;}
	if (defined $R::tcpport and looks_like_number($R::tcpport)) { $pcfg{'Main.tcpport'} = $R::tcpport;}
	$pcfg{'Main.allowed_remote_ips'} =  $R::allowed_remote_ips;
	
	if ( grep $_ == $R::security_mode, ('unsecure', 'restricted') ) { $pcfg{'Main.security_mode'} = $R::security_mode;}
	if ( grep $_ == $R::security_mode, ('unsecure', 'restricted') ) { $pcfg{'Main.security_mode'} = $R::security_mode;}
	
	tied(%pcfg)->write();
	my $killscript = "sudo $lbcgidir/bin/restart_tcp2shell.sh  > /dev/null &";
	system($killscript);
		
	return;
	
}

