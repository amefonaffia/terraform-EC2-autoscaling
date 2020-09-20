#! /bin/bash        
yum update -y
yum install httpd -y
systemctl start httpd
systemctl restart httpd
echo "<h1>Deployed via Terraform</h1>" | sudo tee /var/www/html/index.html