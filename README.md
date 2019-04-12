# FHEM-PIP
FHEM Module to integrate the MPP Solar / Axpert PIP Hybrid Solar Inverters

The PIP needs to be accessible over a network TCP connection. Easiest way to accomplish this would be to
attach it to a Raspberry Pi using a USB-COM-Adapter and then installing the ser2net daemon.

Then install the module using this command:

update all https://raw.githubusercontent.com/sw-home/FHEM-Tesla/master/controls_pip.txt

and define a module like this:

define PIP MppSolarPip <IP address> <port> <refresh interval in seconds> <timeout in seconds>

for example:

define PIP MppSolarPip 192.168.1.17 2002 61 2

