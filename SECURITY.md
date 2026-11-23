# Security

Please report vulnerabilities privately: on GitHub, open the **Security** tab and choose **Report a vulnerability**. Don't open a public issue.

Headwaiter reads other processes' command lines, working directories and project manifests, and sends signals to your own processes. It runs without the App Sandbox because the sandbox blocks those calls ([details](docs/app-sandbox.md)). Anything that makes it stop the wrong process, run something, or send data off your Mac is in scope. So is anything that gets an update installed without a valid signature: the update feed and every download must be signed with the release key, and updates are never installed without asking.
