#!/usr/bin/env python3
import json
import os
import requests

# Base URL for all requests
BASE_URL = "http://localhost:9001"
ROOT_TOKEN = os.getenv("SYNQLY_ROOT_TOKEN")

admin_email = os.getenv("ADMIN_EMAIL")
admin_password = os.getenv("ADMIN_PASSWORD")
organization_name = os.getenv("SYNQLY_ORG_NAME")

# Common headers
headers = {
    "Content-Type": "application/json",
    "Authorization": f"Bearer {ROOT_TOKEN}"
}

def print_response(response, description):
    """Helper function to print response details"""
    print(f"\n{description}")
    print(f"Status Code: {response.status_code}")
    try:
        json_response = response.json()
        print(f"Response: {json.dumps(json_response, indent=2)}")
        return json_response
    except ValueError:
        print(f"Response Text: {response.text}")
        return None

# Step 1: Get id of the root organization (Synqly Backoffice)
def get_root_organization():
    url = f"{BASE_URL}/v1/private/synqly-backoffice"
    print(f"\nRequesting root organization from: {url}")

    response = requests.get(url, headers=headers)
    json_response = print_response(response, "Root Organization Response")

    if json_response and 'id' in json_response['result']:
        return json_response['result']['id']
    else:
        raise Exception("Failed to get root organization ID")

# Step 2: Get organization
def get_organization(organization_name):
    url = f"{BASE_URL}/v1/organizations/{organization_name}"
    print(f"\nRequesting organization details from: {url}")

    response = requests.get(url, headers=headers)
    json_response = print_response(response, "Organization Response")

    if json_response and 'id' in json_response['result']:
        return json_response['result']['id'], json_response['result'].get('refresh_token_id')
    else:
        raise Exception("Failed to get organization ID or refresh token ID")

# Step 3: Login to get token for admin user
def login(root_organization_id, organization_id):
    url = f"{BASE_URL}/v1/auth/private/{root_organization_id}/{organization_id}"
    print(f"\nLogging in: {url}")

    payload = {
        "name": admin_email,
        "secret": admin_password
    }

    response = requests.post(url, headers=headers, json=payload)
    json_response = print_response(response, "Login Response")

    try:
        return json_response['result']['token']['access']['secret']
    except Exception as e:
        raise Exception(f"Failed to get token for admin user: {e}")

# Step 4: Reset organization token
def reset_organization_token(organization_id, refresh_token_id, bearer_token):
    url = f"{BASE_URL}/v1/tokens/{organization_id}/{refresh_token_id}/reset"
    print(f"\nResetting organization token: {url}")

    # Update authorization header with new bearer token
    token_headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {bearer_token}"
    }

    response = requests.put(url, headers=token_headers)
    json_response = print_response(response, "Token Reset Response")

    if json_response:
        return json_response['result']
    else:
        raise Exception("Failed to reset organization token")

def main():
    try:
        # Get root organization ID
        root_organization_id = get_root_organization()
        print(f"Root Organization ID: {root_organization_id}")

        # Get organization details
        organization_id, refresh_token_id = get_organization(organization_name)
        print(f"Organization ID: {organization_id}")
        print(f"Refresh Token ID: {refresh_token_id}")

        # Login to get bearer token
        admin_token = login(root_organization_id, organization_id)
        print(f"Admin Access Token: {admin_token}")

        # Reset organization token
        reset_result = reset_organization_token(organization_id, refresh_token_id, admin_token)
        print()
        print(f"Organization Access Token: {reset_result['primary']['access']['secret']}")
        print(f"Organization Refresh Token: {reset_result['primary']['refresh']['secret']}")


    except Exception as e:
        print(f"Error: {str(e)}")

if __name__ == "__main__":
    main()
