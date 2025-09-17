mkdir certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/x.brimble.app.key -out certs/x.brimble.app.crt \
  -subj "/CN=x.brimble.app"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/y.brimble.app.key -out certs/y.brimble.app.crt \
  -subj "/CN=y.brimble.app"