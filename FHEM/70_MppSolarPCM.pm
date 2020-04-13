##############################################################################
#
# 70_MppSolarPCM.pm
#
# A FHEM module to read power/energy values from a
# MPP Solar PCM60X Solar Charger
#
# written 2020 by Stefan Willmeroth <swi@willmeroth.com>
#
##############################################################################
#
# usage:
# define <name> MppSolarPCM <host> <port> [<interval> [<timeout>]]
#
# example:
# define sv MppSolarPCM raspibox 2001 15000 60
#
# If <interval> is positive, new values are read every <interval> seconds.
# If <interval> is 0, new values are read whenever a get request is called
# on <name>. The default for <interval> is 300 (i.e. 5 minutes).
#
##############################################################################
#
# Copyright notice
#
# (c) 2020 Stefan Willmeroth <swi@willmeroth.com>
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

my @MppSolarPCM_gets = (
            'pvVoltage',                    # V
            'batteryVoltage',               # V
            'batteryChargeAmps',            # A
            'externalBatteryVoltage',       # V
            'pvCurrentAmps',                # A
            'pvPower',                      # W
            'heatsinkTemp',                 # C
            'unknown1',
            'batteryTemp',                  # C
            'nextEqualisation',             # days
            'deviceStatus',                 # bits unknown
            'solarEnergyDay',               # kWh roughly summed up from pvPower reading

            'BatteryAbsorptionChargingVoltage', # Setting battery C.V. (constant voltage) charging voltage
            'BatteryFloatChargingVoltage'   # Setting battery float charging voltage
            );

sub
MppSolarPCM_Initialize($)
{
  my ($hash) = @_;

  $hash->{DefFn}    = "MppSolarPCM_Define";
  $hash->{UndefFn}  = "MppSolarPCM_Undef";
  $hash->{SetFn}    = "MppSolarPCM_Set";
  $hash->{GetFn}    = "MppSolarPCM_Get";
  $hash->{AttrList} = "loglevel:0,1,2,3,4,5 event-on-update-reading event-on-change-reading event-min-interval stateFormat";
}

sub
MppSolarPCM_Define($$)
{
  my ($hash, $def) = @_;

  my @args = split("[ \t]+", $def);

  if (int(@args) < 3)
  {
    return "MppSolarPCM_Define: too few arguments. Usage:\n" .
           "define <name> MppSolarPCM <host> <port> [<interval> [<timeout>]]";
  }

  $hash->{Host} = $args[2];
  $hash->{Port} = $args[3];

  $hash->{Interval} = int(@args) >= 5 ? int($args[4]) : 300;
  $hash->{Timeout}  = int(@args) >= 6 ? int($args[5]) : 4;

  # config variables
  $hash->{Invalid}    = -1;    # default value for invalid readings

  MppSolarPCM_Update($hash);

  Log3 $hash->{NAME}, 2, "$hash->{NAME} will read from MppSolarPCM at $hash->{Host}:$hash->{Port} " .
         ($hash->{Interval} ? "every $hash->{Interval} seconds" : "for every 'get $hash->{NAME} <key>' request");

  return undef;
}

sub
MppSolarPCM_Update($)
{
  my ($hash) = @_;

  if ($hash->{Interval} > 0) {
    InternalTimer(gettimeofday() + $hash->{Interval}, "MppSolarPCM_Update", $hash, 0);
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

      # request current statistics
      my $res = MppSolarPCM_Request($hash, $socket, "QPIGS\xB7\xA9\r");

      if ($res and ord($res) == 0x28 and
               ord(substr($res, length($res)-1)) == 13 and
               scalar (@vals = split(/ +/, substr($res,1,length($res)-4))) == 11)
      {
        my @vals = split(/ +/, substr($res,1,length($res)-4));

        # parse the result from inverter to dedicated values
        for my $i (0..MppSolarPCM_max(scalar (@vals)-1,10))
        {
          if (defined($vals[$i]))
          {
            $readings{$MppSolarPCM_gets[$i]} = 0 + $vals[$i];
          }
        }

        alarm 0;
        $success = 1;

      } else {
        Log3 $hash->{NAME}, 2, "Invalid QPIGS response from Inverter: $res";
      }

      # additionally update device settings all ten minutes
      if (ReadingsAge($hash->{NAME},"OutputSourcePriority",601) >= 600)
      {
        $res = MppSolarPCM_Request($hash, $socket, "QPIRI\xF8\x54\r");

        if ($res and ord($res) == 0x28 and
                 ord(substr($res, length($res)-1)) == 13 and
                 scalar (@vals = split(/ +/, substr($res,1,length($res)-4))) >= 13)
        {
          $hash->{BatteryRatingVoltage} = $vals[1];
          $readings{BatteryAbsorptionChargingVoltage} = $vals[3];
          $readings{BatteryFloatChargingVoltage} = $vals[4];
        } else {
          Log3 $hash->{NAME}, 2, "Invalid QPIRI response from Inverter: $res";
        }
      }

      close($socket);

    } # socket okay
  }; # eval
  alarm 0;

  # update Readings
  readingsBeginUpdate($hash);
  if ($success) {
    Log3 $hash->{NAME}, 4, "$hash->{NAME} got fresh values from MppSolarPCM";

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

    for my $get (@MppSolarPCM_gets)
    {
      readingsBulkUpdate($hash, $get, $readings{$get});
    }

    my $state = sprintf("%.0fW %.2fV %.2fkWh", $readings{pvPower}, $readings{batteryVoltage}, $readings{solarEnergyDay});
    readingsBulkUpdate($hash, "state", $state);
  } else {
    Log3 $hash->{NAME}, 4, "$hash->{NAME} was unable to get fresh values from MppSolarPCM";
    readingsBulkUpdate($hash, "state", "Offline");
  }
  readingsEndUpdate($hash, $init_done);

  return undef;
}

sub
MppSolarPCM_Request($@)
{
  my ($hash, $socket, $cmd) = @_;

  Log3 $hash->{NAME}, 4, "Inverter command: " . $cmd;
  printf $socket $cmd;

  return MppSolarPCM_Reread($hash, $socket);
}

sub
MppSolarPCM_Reread($@)
{
  my ($hash, $socket) = @_;

  my $singlechar;
  my $res;

  do {
      $socket->read($singlechar,1);

      $res = $res . $singlechar if (!(length($res) == 0 && ord($singlechar) == 13))

  } while (length($res) == 0 || ord($singlechar) != 13);

  Log3 $hash->{NAME}, 4, "Inverter returned:\n" . MppSolarPCM_hexdump($res);
  return $res;
}

sub
MppSolarPCM_Set($@)
{
  my ($hash, @a) = @_;
  return "no set value specified" if(int(@a) < 2);
  return " BatteryAbsorptionChargingVoltage BatteryFloatChargingVoltage" if($a[1] eq "?");

  shift @a;
  my $command = $a[0];
  my $pgm = $a[1];
  my $msg;
  my $res;
  my $msgWithCrc;

  Log3 $hash->{NAME}, 3, "set command: $command to value $pgm";

  if($command eq "BatteryAbsorptionChargingVoltage") {
    $msg = "PBAV" . $pgm;

  } elsif($command eq "BatteryFloatChargingVoltage") {
    $msg = "PBFV" . $pgm;

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
      $res = MppSolarPCM_Request($hash, $socket, $msgWithCrc);
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
MppSolarPCM_Get($@)
{
  my ($hash, @args) = @_;

  return 'MppSolarPCM_Get needs two arguments' if (@args != 2);

  MppSolarPCM_Update($hash) unless $hash->{Interval};

  my $get = $args[1];
  my $val = $hash->{Invalid};

  if (defined($hash->{READINGS}{$get})) {
    $val = $hash->{READINGS}{$get}{VAL};
  } else {
    return "MppSolarPCM_Get: no such reading: $get";
  }

  Log3 $hash->{NAME}, 3, "$args[0] $get => $val";

  return $val;
}

sub
MppSolarPCM_Undef($$)
{
  my ($hash, $args) = @_;

  RemoveInternalTimer($hash) if $hash->{Interval};

  return undef;
}

1;

sub MppSolarPCM_max ($$) { $_[$_[0] < $_[1]] }

sub MppSolarPCM_hexdump($)
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
