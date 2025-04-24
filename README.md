
# Bedrock infrastructure as code for AWS Bedrock

This is a trivial example of the infrastructure needed to provision enough aws infrastructure to run a basic app to talk with bedrock. 

## Usage

```sh
terraform init
aws configure # set an aws access key id and secret, so aws terraform provider can do what it needs
terraform plan
terraform apply
```

