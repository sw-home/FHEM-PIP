# FHEM-PIP
FHEM Module to integrate the MPP Solar / Axpert PIP Hybrid Solar Inverters

The PIP needs to be accessible over a network TCP connection. Easiest way to accomplish this would be to
attach it to a Raspberry Pi using a USB-COM-Adapter and then installing the ser2net daemon.

Then install the module using this command:

update all https://raw.githubusercontent.com/sw-home/FHEM-PIP/master/controls_pip.txt

and define a module like this:

define PIP MppSolarPip IP_address port refresh_interval_in_seconds timeout_in_seconds

for example:

define PIP MppSolarPip 192.168.1.17 2002 61 2

To get a nice STATE line:

```perl
attr PIP stateFormat {sprintf("%s (PV %.0f W %.2f kWh Bat %.2f V Out %.0f W)",ReadingsVal("PIP","state",0),ReadingsVal("PIP","pvPower",0),ReadingsVal("PIP","solarEnergyDay",0),ReadingsVal("PIP","batteryVoltage",0),ReadingsVal("PIP","outputPower",0))}
```

and to reduce logging set

```perl
attr PIP event-min-interval batteryChargeAmps:600,batteryDischargeAmps:600,batterySoC,batteryVoltage,opMode,outputLoad:600,outputPower:600,outputVA:600,pvPower,solarEnergyDay

attr PIP event-on-change-reading batteryChargeAmps,batteryDischargeAmps,batterySoC,batteryVoltage,opMode,outputLoad,outputPower,outputVA,pvPower,solarEnergyDay
```
