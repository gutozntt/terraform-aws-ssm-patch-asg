resource "aws_ssm_document" "this" {
  name            = "${var.name}-automation"
  document_format = "YAML"
  document_type   = "Automation"
  tags            = var.tags

  content = <<DOC
---
description: Systems Manager Automation Demo - Patch AMI and Update ASG
schemaVersion: '0.3'
assumeRole: '{{ AutomationAssumeRole }}'
parameters:
  AutomationAssumeRole:
    type: String
    description: '(Required) The ARN of the role that allows Automation to perform the actions on your behalf. If no role is specified, Systems Manager Automation uses your IAM permissions to execute this document.'
    default: ''
  SourceAMI:
    type: String
    description: '(Required) The ID of the AMI you want to patch.'
  SubnetId:
    type: String
    description: '(Required) The ID of the subnet where the instance from the SourceAMI parameter is launched.'
  SecurityGroupIds:
    type: StringList
    description: '(Required) The IDs of the security groups to associate with the instance launched from the SourceAMI parameter.'
  NewAMI:
    type: String
    description: '(Optional) The name of of newly patched AMI.'
    default: 'patchedAMI-{{global:DATE_TIME}}'
  TargetASG:
    type: String
    description: '(Required) The name of the Auto Scaling group you want to update.'
  InstanceProfile:
    type: String
    description: '(Required) The name of the IAM instance profile you want the source instance to use.'
  SnapshotId:
    type: String
    description: (Optional) The snapshot ID to use to retrieve a patch baseline snapshot.
    default: ''
  RebootOption:
    type: String
    description: '(Optional) Reboot behavior after a patch Install operation. If you choose NoReboot and patches are installed, the instance is marked as non-compliant until a subsequent reboot and scan.'
    allowedValues:
      - NoReboot
      - RebootIfNeeded
    default: RebootIfNeeded
  Operation:
    type: String
    description: (Optional) The update or configuration to perform on the instance. The system checks if patches specified in the patch baseline are installed on the instance. The install operation installs patches missing from the baseline.
    allowedValues:
      - Install
      - Scan
    default: Install
  AmiParameter:
    type: String
    description: '(Required) The name of the AMI Parameter in SSM Parameter Store to update.'
  LtParameter:
    type: String
    description: '(Required) The name of the Launch Template Parameter in SSM Parameter Store to update.'
  PatchBaselineName:
    type: String
    description: '(Optional) The name of the patch baseline to apply.'
    default: AWS-RunPatchBaseline
  LaunchTemplatePrefix:
    type: String
    description: 'Launch Template Prefix.'
  RetentionDays:
    type: String
    description: 'AMIs and LTs Retention Days.'
mainSteps:
  - name: startInstances
    action: 'aws:runInstances'
    timeoutSeconds: 1200
    maxAttempts: 1
    onFailure: Abort
    inputs:
      ImageId: '{{ SourceAMI }}'
      InstanceType: m5.large
      MinInstanceCount: 1
      MaxInstanceCount: 1
      IamInstanceProfileName: '{{ InstanceProfile }}'
      SubnetId: '{{ SubnetId }}'
      SecurityGroupIds: '{{ SecurityGroupIds }}'
  - name: verifyInstanceManaged
    action: 'aws:waitForAwsResourceProperty'
    timeoutSeconds: 600
    inputs:
      Service: ssm
      Api: DescribeInstanceInformation
      InstanceInformationFilterList:
        - key: InstanceIds
          valueSet:
            - '{{ startInstances.InstanceIds }}'
      PropertySelector: '$.InstanceInformationList[0].PingStatus'
      DesiredValues:
        - Online
    onFailure: 'step:terminateInstance'
  - name: installPatches
    action: 'aws:runCommand'
    timeoutSeconds: 7200
    onFailure: Abort
    inputs:
      DocumentName: '{{PatchBaselineName}}'
      Parameters:
        SnapshotId: '{{SnapshotId}}'
        RebootOption: '{{RebootOption}}'
        Operation: '{{Operation}}'
      InstanceIds:
        - '{{ startInstances.InstanceIds }}'
  - name: stopInstance
    action: 'aws:changeInstanceState'
    maxAttempts: 1
    onFailure: Continue
    inputs:
      InstanceIds:
        - '{{ startInstances.InstanceIds }}'
      DesiredState: stopped
  - name: createImage
    action: 'aws:createImage'
    maxAttempts: 1
    onFailure: Continue
    inputs:
      InstanceId: '{{ startInstances.InstanceIds }}'
      ImageName: '{{ NewAMI }}'
      NoReboot: false
      ImageDescription: Patched AMI created by Automation
  - name: terminateInstance
    action: 'aws:changeInstanceState'
    maxAttempts: 1
    onFailure: Continue
    inputs:
      InstanceIds:
        - '{{ startInstances.InstanceIds }}'
      DesiredState: terminated
  - name: updateASG
    action: 'aws:executeScript'
    timeoutSeconds: 300
    maxAttempts: 1
    onFailure: Abort
    inputs:
      Runtime: python3.8
      Handler: update_asg
      InputPayload:
        TargetASG: '{{TargetASG}}'
        NewAMI: '{{createImage.ImageId}}'
        AmiParameter: '{{AmiParameter}}'
        LtParameter: '{{LtParameter}}'
        LaunchTemplatePrefix: '{{LaunchTemplatePrefix}}'
        RetentionDays: '{{RetentionDays}}'
      Script: |-
        from __future__ import print_function
        import datetime
        import time
        import json
        import time
        import boto3

        # create auto scaling and ec2 client
        asg = boto3.client('autoscaling')
        ec2 = boto3.client('ec2')
        ssm = boto3.client('ssm')

        def update_asg(event, context):
            print("Received event: " + json.dumps(event, indent=2))

            target_asg = event['TargetASG']
            new_ami = event['NewAMI']
            ami_ssm_parameter = event['AmiParameter']
            lt_ssm_parameter = event['LtParameter']
            launch_template_prefix = event['LaunchTemplatePrefix']
            retention_days = event['RetentionDays']

            # get object for the ASG we're going to update, filter by name of target ASG
            asg_query = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[target_asg])
            if 'AutoScalingGroups' not in asg_query or not asg_query['AutoScalingGroups']:
                return 'No ASG found matching the value you specified.'

            # gets details of an instance from the ASG that we'll use to model the new launch template after
            source_instance_id = asg_query.get('AutoScalingGroups')[0]['Instances'][0]['InstanceId']
            instance_properties = ec2.describe_instances(
                InstanceIds=[source_instance_id]
            )
            source_instance = instance_properties['Reservations'][0]['Instances'][0]

            # create list of security group IDs
            security_groups = []
            for group in source_instance['SecurityGroups']:
                security_groups.append(group['GroupId'])

            # create a list of dictionary objects for block device mappings
            mappings = []
            for block in source_instance['BlockDeviceMappings']:
                volume_query = ec2.describe_volumes(
                    VolumeIds=[block['Ebs']['VolumeId']]
                )
                volume_details = volume_query['Volumes']
                device_name = block['DeviceName']
                volume_size = volume_details[0]['Size']
                volume_type = volume_details[0]['VolumeType']
                device = {'DeviceName': device_name, 'Ebs': {'VolumeSize': volume_size, 'VolumeType': volume_type}}
                mappings.append(device)

            # create new launch template using details returned from instance in the ASG and specify the newly patched AMI
            time_stamp = time.time()
            time_stamp_string = datetime.datetime.fromtimestamp(time_stamp).strftime('%m-%d-%Y_%H-%M-%S')
            new_template_name = f'{launch_template_prefix}_{time_stamp_string}'
            delete_date = datetime.date.today() + datetime.timedelta(days=int(retention_days))
            delete_fmt = delete_date.strftime('%m-%d-%Y')
            try:
                ec2.create_tags(
                    Resources = [ new_ami ],
                    Tags = [
                        {
                            'Key': 'DeleteAfter',
                            'Value': delete_fmt
                        }
                    ]
                )
                ec2.create_launch_template(
                    LaunchTemplateName=new_template_name,
                    TagSpecifications=[
                        {
                            'ResourceType': 'launch-template',
                            'Tags': [
                                {
                                    'Key': 'DeleteAfter',
                                    'Value': delete_fmt
                                },
                            ]
                        },
                    ],
                    LaunchTemplateData={
                        'BlockDeviceMappings': mappings,
                        'ImageId': new_ami,
                        'InstanceType': source_instance['InstanceType'],
                        'IamInstanceProfile': {
                            'Arn': source_instance['IamInstanceProfile']['Arn']
                        },
                        'KeyName': source_instance['KeyName'],
                        'SecurityGroupIds': security_groups,
                        'TagSpecifications': [
                            {
                                'ResourceType': 'instance',
                                'Tags': [
                                    {
                                        'Key': 'Name',
                                        'Value': launch_template_prefix
                                    },
                                ]
                            },
                        ],
                    }
                )
            except Exception as e:
                return f'Exception caught: {str(e)}'
            else:
                # update ASG to use new launch template
                asg.update_auto_scaling_group(
                    AutoScalingGroupName=target_asg,
                    LaunchTemplate={
                        'LaunchTemplateName': new_template_name
                    }
                )
                # update SSM parameters with new AMI and Launch Template
                ssm.put_parameter(
                  Name=ami_ssm_parameter,
                  Value=new_ami,
                  Overwrite=True
                )
                ssm.put_parameter(
                  Name=lt_ssm_parameter,
                  Value=new_template_name,
                  Overwrite=True
                )
                asg.start_instance_refresh(
                  AutoScalingGroupName=target_asg,
                  Strategy='Rolling'
                )
                # Clean Up LTs and AMIs
                old_lts = ec2.describe_launch_templates(
                      Filters=[
                          {
                              'Name': 'tag-key',
                              'Values': [
                                  'DeleteAfter',
                              ]
                          },
                      ],
                ).get('LaunchTemplates', [])

                today_time = datetime.datetime.now().strftime('%m-%d-%Y')
                today_date = time.strptime(today_time, '%m-%d-%Y')

                for template in old_lts:
                    template_id = template['LaunchTemplateId']
                    deletion_date = [t.get('Value') for t in template['Tags'] if t['Key'] == 'DeleteAfter'][0]
                    delete_date = time.strptime(deletion_date, "%m-%d-%Y")
                    if delete_date <= today_date:
                        ec2.delete_launch_template(
                            LaunchTemplateId = template_id
                        )
                
                old_amis = ec2.describe_images(
                      Filters=[
                          {
                              'Name': 'tag-key',
                              'Values': [
                                  'DeleteAfter',
                              ]
                          },
                      ],
                ).get('Images', [])
                for image in old_amis:
                    ami_id = image['ImageId']
                    deletion_date = [t.get('Value') for t in image['Tags'] if t['Key'] == 'DeleteAfter'][0]
                    delete_date = time.strptime(deletion_date, "%m-%d-%Y")
                    if delete_date <= today_date:
                        ec2.deregister_image(
                            ImageId = ami_id
                        )

                return f'Updated ASG {target_asg} with new launch template {new_template_name} which uses AMI {new_ami}.'
outputs:
  - createImage.ImageId
DOC
}