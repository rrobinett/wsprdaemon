# ka9q-web 

This software builds in reference to ka9q-radio and requires no specific configuration.  
wsprdaemon typically starts it automatically.  You invoke it manually, if necessary, thus:
```
ka9q-web -m your-radiod-status-stream.local &
```
where "your-radiod-status-stream" is the name specified in your radiod@.conf (often hf.local or hf-status.local)

## Viewing the ka9q-web spectrum display

Logged in an running everything locally, direct your browser to http://localhost:8081.

If managing the computer remotely using ssh, you can set up an ssh tunnel from the remote computer to your local computer like this:

From your local machine, run:
```
ssh -L 8081:localhost:8081 wsprdaemon@XX
```
where XX is the ip address or name of the remote computer running ka9q-web. (Substitute another username if not running wsprdaemon eponymously.)

Then direct your browser to http://localhost:8081 to view ka9q-web from the XX remote machine.


**John Melton G0ORX** started this with a proof-of-concept version in late 2023. This adjunct to ka9q-radio displays a spectrum, waterfall, and other data from radiod.  **Scott Newell N5TNL** has since improved it dramatically in collaboration with **Rob Robinett AI6VN**, **Phil Karn KA9Q**, **Glenn Elmore N6GN**, **Jim Lill WA2ZKD**, and desultory kibbitzers.  

- Web Server by John Melton, G0ORX (https://github.com/g0orx/ka9q-radio)
- ka9q-radio by Phil Karn, KA9Q (https://github.com/ka9q/ka9q-radio)
- Onion Web Framework by David Moreno (https://github.com/davidmoreno/onion)
- Spectrum/Waterfall Display by Jeppe Ledet-Pedersen (https://github.com/jledet/waterfall)
