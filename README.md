# Rolling Update with Docker Compose
Rolling updates are a feature provided by Docker Swarm and other automation deployment tools, allowing for seamless updates of services. However, docker-compose currently lacks native support for this feature. While it may be supported in future releases, this repository provides scripts to enable rolling updates with docker-compose.

## Instructions for Testing the Scripts with a Simple Service
The repository includes a Dockerfile and a simple Node.js server for generating images for testing the rolling update. Follow the steps below to generate the required images and test the rolling update process:
1. Generating First Healthy Image
   > docker build . -t service:healthy1
2. Generating Second Healthy Image
   Modify server.js to change the response from "Hello World 1!" to "Hello World 2!".
   > docker build . -t service:healthy2
3. Generating the Unhealthy Image
   Modify the HTTP response in server.js to return a status code of 400.
   > docker build . -t service:unhealthy
4. Starting Services
   Run the update script to start the services defined in the docker-compose file.
   > ./update.sh
5. Monitoring Services
   > ./infinite_request.sh
6. Updating Services
   Modify the Docker Compose file to update the image with the second healthy image, then run the update script again.
   > ./update.sh
8. Deploying an Unsuccessful Change
   Update the Docker Compose file with the unhealthy image and run the update script again.
   > ./update.sh

## Conclusion
This repository provides scripts for enabling rolling updates with Docker Compose, allowing for seamless deployment of services. By following the provided instructions, users can test and deploy changes to their services with confidence.
