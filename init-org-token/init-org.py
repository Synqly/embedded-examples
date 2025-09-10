#!/usr/bin/env python3
import json
import os
import requests

# Base URL for all requests
BASE_URL = os.getenv("BASE_URL") if os.getenv("BASE_URL") else "http://localhost:8000"

admin_email = os.getenv("ADMIN_EMAIL")
admin_password = os.getenv("ADMIN_PASSWORD")
organization_name = os.getenv("SYNQLY_ORG_NAME")

# Common headers
headers = {
    "Content-Type": "application/json",
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

# Step 1: Login to get token for admin user
def login():
    url = f"{BASE_URL}/v1/auth/logon/{organization_name}"
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

# Step 2: Get organization details
def get_organization_details(bearer_token):
    url = f"{BASE_URL}/v1/organization"
    print(f"\nGetting organization details: {url}")
    headers["Authorization"] = f"Bearer {bearer_token}"
    response = requests.get(url, headers=headers)
    json_response = print_response(response, "Organization Details Response")
    return json_response['result']

# Step 3: Reset organization token
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
        # Login to get bearer token
        admin_token = login()

        # Get organization details
        organization_details = get_organization_details(admin_token)
        print(f"Organization Details: {organization_details}")
        organization_id = organization_details['id']
        refresh_token_id = organization_details['refresh_token_id']

        # Reset organization token
        reset_result = reset_organization_token(organization_id, refresh_token_id, admin_token)
        print()
        print(f"Organization Access Token: {reset_result['primary']['access']['secret']}")
        print(f"Organization Refresh Token: {reset_result['primary']['refresh']['secret']}")


    except Exception as e:
        print(f"Error: {str(e)}")

if __name__ == "__main__":
    main()
