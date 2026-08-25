import json
import boto3

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('Statistics')

def lambda_handler(event, context):
	response = table.get_item(Key={'property':'Views'})
	newViews = response['Item']['total'] + 1

	table.put_item(Item={'property':'Views', 'total':newViews})

	print(newViews)
    
	return {
        "statusCode": 200,
        "headers": {
            'Content-Type': 'application/json',
        },
        "body": newViews,
    }