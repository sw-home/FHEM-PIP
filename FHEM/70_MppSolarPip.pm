##############################################################################
#
# 70_MppSolarPip.pm
#
# A FHEM module to read power/energy values from a
# MPP Solar PIP Hybrid Inverter
#
# written 2018 by Stefan Willmeroth <swi@willmeroth.com>
#
##############################################################################
#
# usage:
# define <name> MppSolarPip <host> <port> [<interval> [<timeout>]]
#
# example:
# define sv MppSolarPip raspibox 2001 15000 60
#
# If <interval> is positive, new values are read every <interval> seconds.
# If <interval> is 0, new values are read whenever a get request is called
# on <name>. The default for <interval> is 300 (i.e. 5 minutes).
#
##############################################################################
#
# Copyright notice
#
# (c) 2018 Stefan Willmeroth <swi@willmeroth.com>
#
# This script is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# The GNU General Public License can be found at
# http://www.gnu.org/copyleft/gpl.html.
#
# This script is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# This copyright notice MUST APPEAR in all copies of the script!
#
##############################################################################

package main;

use strict;
use warnings;

use IO::Socket::INET;
use Digest::CRC qw(crc32 crc16 crcccitt crc crc8);

my %MppSolarPip_OpModes = (
  'P' => 'Power on mode',
  'S' => 'Standby mode',
  'L' => 'Line Mode', 
  'B' => 'Battery mode', 
  'F' => 'Fault mode',
  'H' => 'Power saving Mode'
);
my %MppSolarPip_InverterModes = (
  "Utility"         => "POP00",
  "Solar",          => "POP01",
  "SBU"             => "POP02"
);
my %MppSolarPip_InverterModeCommands = (
  "Utility"         => "POP00\xc2\x48\r",
  "Solar",          => "POP01\xd2\x69\r",
  "SBU"             => "POP02\xe2\x0b\r"
);
my %MppSolarPip_ChargerModes = (
  "UtilityFirst"    => "PCP00",
  "SolarFirst"      => "PCP01",
  "SolarAndUtility" => "PCP02",
  "SolarOnly"       => "PCP03"
);
my %MppSolarPip_BatteryRecharge = (
  "12.0" => "11.0,11.3,11.5,11.8,12.0,12.3,12.5,12.8",
  "24.0" => "22.0,22.5,23.0,23.5,24.0,24.5,25.0,25.5",
  "48.0" => "44.0,45.0,46.0,47.0,48.0,49.0,50.0,51.0"
);
my %MppSolarPip_BatteryReDischarge = (
  "12.0" => "00.0,12.0,12.3,12.5,12.8,13.0,13.3,13.5,13.8,14.0,14.3,14.5",
  "24.0" => "00.0,24.0,24.5,25.0,25.5,26.0,26.5,27.0,27.5,28.0,28.5,29.0",
  "48.0" => "00.0,48.0,49.0,50.0,51.0,52.0,53.0,54.0,55.0,56.0,57.0,58.0"
);

my @MppSolarPip_gets = (
            'gridVoltage', 'gridFreq',      # V, Hz
            'outputVoltage', 'outputFreq',  # V, Hz
            'outputVA',                     # Inverter power VA
            'outputPower',                  # Inverter power W
            'outputLoad',                   # Inverter load percentage
            'busVoltage',                   # V
            'batteryVoltage',               # V
            'batteryChargeAmps',            # A
            'batterySoC',                   # % (state of charge)
            'heatsinkTemp',                 # C
            'pvCurrentAmps',                # A
            'pvVoltage',                    # V
            'batteryVoltageSCC',            # V
            'batteryDischargeAmps',         # A
            'deviceStatus',                 # b7: add SBU priority version, 1:yes,0:no
                                            # b6: configuration status: 1: Change 0: unchanged
                                            # b5: SCC firmware version 1: Updated 0: unchanged
                                            # b4: Load status: 0: Load off 1:Load on
                                            # b3: battery voltage to steady while charging
                                            # b2: Charging status( Charging on/off )
                                            # b1: Charging status( SCC charging on/off )
                                            # b0: Charging status( AC charging on/off )
            'unknown1',
            'unknown2',
            'pvPower',                      # W
            'unknown3',

            'opMode',                       # see %MppSolarPip_OpModes
            'solarEnergyDay',               # kWh roughly summed up from pvPower reading

            'OutputSourcePriority',         # Setting see %MppSolarPip_InverterModes
            'ChargerPriority',              # Setting see %MppSolarPip_ChargerModes
            'BatteryRechargeVoltage',       # Setting switch from battery to line mode voltage
            'BatteryReDischargeVoltage',    # Setting switch from line to battery mode voltage, 00.0V means battery is full (charging in float mode)
            'BatteryBulkChargingVoltage',   # Setting battery C.V. (constant voltage) charging voltage
            'BatteryFloatChargingVoltage'   # Setting battery float charging voltage
            );

sub
MppSolarPip_Initialize($)
{
  my ($hash) = @_;

  $hash->{DefFn}    = "MppSolarPip_Define";
  $hash->{UndefFn}  = "MppSolarPip_Undef";
  $hash->{SetFn}    = "MppSolarPip_Set";
  $hash->{GetFn}    = "MppSolarPip_Get";
  $hash->{AttrList} = "loglevel:0,1,2,3,4,5 event-on-update-reading event-on-change-reading event-min-interval stateFormat";
}

sub
MppSolarPip_Define($$)
{
  my ($hash, $def) = @_;

  my @args = split("[ \t]+", $def);

  if (int(@args) < 3)
  {
    return "MppSolarPip_Define: too few arguments. Usage:\n" .
           "define <name> MppSolarPip <host> <port> [<interval> [<timeout>]]";
  }

  $hash->{Host} = $args[2];
  $hash->{Port} = $args[3];

  $hash->{Interval} = int(@args) >= 5 ? int($args[4]) : 300;
  $hash->{Timeout}  = int(@args) >= 6 ? int($args[5]) : 4;

  # config variables
  $hash->{Invalid}    = -1;    # default value for invalid readings

  MppSolarPip_Update($hash);

  Log3 $hash->{NAME}, 2, "$hash->{NAME} will read from MppSolarPip at $hash->{Host}:$hash->{Port} " .
         ($hash->{Interval} ? "every $hash->{Interval} seconds" : "for every 'get $hash->{NAME} <key>' request");

  return undef;
}

sub
MppSolarPip_Update($)
{
  my ($hash) = @_;

  if ($hash->{Interval} > 0) {
    InternalTimer(gettimeofday() + $hash->{Interval}, "MppSolarPip_Update", $hash, 0);
  }

  Log3 $hash->{NAME}, 4, "$hash->{NAME} tries to contact Inverter at $hash->{Host}:$hash->{Port}";

  my $success = 0;
  my %readings = ();
  my @vals;
  my $retries  = 2;

  eval {
    local $SIG{ALRM} = sub { die 'timeout'; };
    alarm $hash->{Timeout};

    my $socket = IO::Socket::INET->new(PeerAddr => $hash->{Host},
                                         PeerPort => $hash->{Port},
                                         Timeout  => $hash->{Timeout});

    if ($socket and $socket->connected())
    {
      $socket->autoflush(1);

      # request operation mode
      my $res = MppSolarPip_Request($hash, $socket, "QMOD\x49\xC1\r");

      READ_SV:
      if ($res and ord($res) == 0x28) # and length($res) == 4)
      {
        $readings{opMode} = substr($res,1,1);
      } else {
        # need to retry?
        if ($retries > 0)
        {
          Log3 $hash->{NAME}, 2, "Invalid QMOD response from Inverter, will reread: $res";
          $retries = $retries - 1;
          $res = MppSolarPip_Reread($hash, $socket);
          goto READ_SV;
        }
      }

      # additionally update device settings all ten minutes
      if (ReadingsAge($hash->{NAME},"OutputSourcePriority",601) >= 600)
      {
        $res = MppSolarPip_Request($hash, $socket, "QPIRI\xF8\x54\r");

        if ($res and ord($res) == 0x28 and
                 ord(substr($res, length($res)-1)) == 13 and
                 scalar (@vals = split(/ +/, substr($res,1,length($res)-4))) >= 23)
        {
          foreach my $key (keys %MppSolarPip_InverterModes) {
            if (index($MppSolarPip_InverterModes{$key}, "0".$vals[16]) > -1) {
              $readings{OutputSourcePriority} = $key;
            }
          }
          foreach my $key (keys %MppSolarPip_ChargerModes) {
            if (index($MppSolarPip_ChargerModes{$key}, "0".$vals[17]) > -1) {
              $readings{ChargerPriority} = $key;
            }
          }
          $hash->{BatteryRatingVoltage} = $vals[7];
          $readings{BatteryRechargeVoltage} = $vals[8];
          $readings{BatteryReDischargeVoltage} = $vals[22];
          $readings{BatteryBulkChargingVoltage} = $vals[10];
          $readings{BatteryFloatChargingVoltage} = $vals[11];
        } else {
          Log3 $hash->{NAME}, 2, "Invalid QPIRI response from Inverter: $res";
        }
      }

      # request current statistics
      $res = MppSolarPip_Request($hash, $socket, "QPIGS\xB7\xA9\r");

      close($socket);

      if ($res and ord($res) == 0x28 and
               ord(substr($res, length($res)-1)) == 13 and
               scalar (@vals = split(/ +/, substr($res,1,length($res)-4))) >= 17)
      {
        my @vals = split(/ +/, substr($res,1,length($res)-4));

        # parse the result from inverter to dedicated values
        for my $i (0..MppSolarPip_max(scalar (@vals)-1,20))
        {
          if (defined($vals[$i]))
          {
            $readings{$MppSolarPip_gets[$i]} = 0 + $vals[$i];
          }
        }

        alarm 0;
        $success = 1;

      } else {
        Log3 $hash->{NAME}, 2, "Invalid QPIGS response from Inverter: $res";
      }
    } # socket okay
  }; # eval
  alarm 0;

  # update Readings
  readingsBeginUpdate($hash);
  if ($success) {
    Log3 $hash->{NAME}, 4, "$hash->{NAME} got fresh values from MppSolarPip";

    # Fix temperature
    if (defined($readings{heatsinkTemp})) {
      $readings{heatsinkTemp} = $readings{heatsinkTemp} / 10;
    }

    # Sum up PV kWh during the day
    my $period = ReadingsAge($hash->{NAME},"solarEnergyDay",0);
    my $periodDay = (split(/\D+/, ReadingsTimestamp($hash->{NAME},"solarEnergyDay",0)))[2];
    my $solarEnergyDay = ReadingsVal($hash->{NAME},"solarEnergyDay",0);
    my $power = ReadingsVal($hash->{NAME},"pvPower",0);
    my $wday = strftime("%d", localtime);
    if ($wday != $periodDay) 
    {
      # fresh start on new day
      $solarEnergyDay = 0;
      Log3 $hash->{NAME}, 2, "new day $wday, was $periodDay";
    }
    $solarEnergyDay += ($power * $period) / 3600000;
    $readings{solarEnergyDay} = $solarEnergyDay;

    for my $get (@MppSolarPip_gets)
    {
      readingsBulkUpdate($hash, $get, $readings{$get});
    }

    readingsBulkUpdate($hash, "state", $MppSolarPip_OpModes{$readings{opMode}});
  } else {
    Log3 $hash->{NAME}, 4, "$hash->{NAME} was unable to get fresh values from MppSolarPip";
    readingsBulkUpdate($hash, "state", "Offline");
  }
  readingsEndUpdate($hash, $init_done);

  return undef;
}

sub
MppSolarPip_Request($@)
{
  my ($hash, $socket, $cmd) = @_;

  Log3 $hash->{NAME}, 4, "Inverter command: " . $cmd;
  printf $socket $cmd;

  return MppSolarPip_Reread($hash, $socket);
}

sub
MppSolarPip_Reread($@)
{
  my ($hash, $socket) = @_;

  my $singlechar;
  my $res;

  do {
      $socket->read($singlechar,1);

      $res = $res . $singlechar if (!(length($res) == 0 && ord($singlechar) == 13))

  } while (length($res) == 0 || ord($singlechar) != 13);

  Log3 $hash->{NAME}, 4, "Inverter returned:\n" . MppSolarPip_hexdump($res);
  return $res;
}

sub
MppSolarPip_Set($@)
{
  my ($hash, @a) = @_;
  return "no set value specified" if(int(@a) < 2);
  return "OutputSourcePriority:"       . (join ",", keys %MppSolarPip_InverterModes) .
         " ChargerPriority:"           . (join ",", keys %MppSolarPip_ChargerModes) .
         " BatteryRechargeVoltage:"    . $MppSolarPip_BatteryRecharge{$hash->{BatteryRatingVoltage}} .
         " BatteryReDischargeVoltage:" . $MppSolarPip_BatteryReDischarge{$hash->{BatteryRatingVoltage}} .
         " BatteryBulkChargingVoltage BatteryFloatChargingVoltage"
		if($a[1] eq "?");

  shift @a;
  my $command = $a[0];
  my $pgm = $a[1];
  my $msg;
  my $res;
  my $msgWithCrc;

  Log3 $hash->{NAME}, 3, "set command: $command to value $pgm";

  if($command eq "OutputSourcePriority") {
    $msgWithCrc = $MppSolarPip_InverterModeCommands{$pgm};

  } elsif($command eq "ChargerPriority") {
    $msg = $MppSolarPip_ChargerModes{$pgm};

  } elsif($command eq "BatteryRechargeVoltage") {
    $msg = "PBCV" . $pgm;

  } elsif($command eq "BatteryReDischargeVoltage") {
    $msg = "PBDV" . $pgm;

  } elsif($command eq "BatteryBulkChargingVoltage") {
    $msg = "PCVV" . $pgm;

  } elsif($command eq "BatteryFloatChargingVoltage") {
    $msg = "PBFT" . $pgm;

  } else {
    return "Unknown set command $command";
  }

  if (!defined $msg && !defined $msgWithCrc) {
    return "Unknown set $command value $pgm";
  }

  if (!defined $msgWithCrc) {
    my $x=sprintf ("%04X",crc($msg,16,0,0,0,0x1021,0));
    $msgWithCrc=sprintf("%s%c%c\r",$msg,hex(substr($x,0,2)),hex(substr($x,2)));
  }

  eval {
    local $SIG{ALRM} = sub { die 'timeout'; };
    alarm $hash->{Timeout};

    my $socket = IO::Socket::INET->new(PeerAddr => $hash->{Host},
                                         PeerPort => $hash->{Port},
                                         Timeout  => $hash->{Timeout});

    if ($socket and $socket->connected())
    {
      $socket->autoflush(1);
      $res = MppSolarPip_Request($hash, $socket, $msgWithCrc);
      close($socket);
    } # socket okay
  }; # eval
  alarm 0;

  if (index($res, "(ACK") == 0)
  {
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, $command, $pgm);
    readingsEndUpdate($hash, $init_done);
  } else {
    return "Setting failed, device answer was: $res";
  }
}

sub
MppSolarPip_Get($@)
{
  my ($hash, @args) = @_;

  return 'MppSolarPip_Get needs two arguments' if (@args != 2);

  MppSolarPip_Update($hash) unless $hash->{Interval};

  my $get = $args[1];
  my $val = $hash->{Invalid};

  if (defined($hash->{READINGS}{$get})) {
    $val = $hash->{READINGS}{$get}{VAL};
  } else {
    return "MppSolarPip_Get: no such reading: $get";
  }

  Log3 $hash->{NAME}, 3, "$args[0] $get => $val";

  return $val;
}

sub
MppSolarPip_Undef($$)
{
  my ($hash, $args) = @_;

  RemoveInternalTimer($hash) if $hash->{Interval};

  return undef;
}

1;

sub MppSolarPip_max ($$) { $_[$_[0] < $_[1]] }

sub MppSolarPip_hexdump($)
{
    my $offset = 0;
    my $result = "";
        
    foreach my $chunk (unpack "(a16)*", $_[0])
    {
        my $hex = unpack "H*", $chunk; # hexadecimal magic
        $chunk =~ tr/ -~/./c;          # replace unprintables
        $hex   =~ s/(.{1,8})/$1 /gs;   # insert spaces
        $result .= sprintf "0x%08x (%05u)  %-*s %s\n",
            $offset, $offset, 36, $hex, $chunk;
        $offset += 16;
    }

    return $result;
}
