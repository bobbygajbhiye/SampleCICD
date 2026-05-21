pipeline {
    agent any

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Set Environment') {
            steps {
                script {
                    if (env.BRANCH_NAME == 'develop') {
                        env.DEPLOY_ENV = 'dev'
                        env.ACR_CREDENTIALS_ID = 'acr-creds-dev'
                        env.AZURE_SP_CREDENTIALS_ID = 'azure-sp-dev'
                    } else if (env.BRANCH_NAME == 'main') {
                        env.DEPLOY_ENV = 'prod'
                        env.ACR_CREDENTIALS_ID = 'acr-creds-prod'
                        env.AZURE_SP_CREDENTIALS_ID = 'azure-sp-prod'
                    } else {
                        env.DEPLOY_ENV = ''
                    }
                }
            }
        }

        stage('Build Images') {
            when {
                expression { env.DEPLOY_ENV in ['dev', 'prod'] }
            }
            steps {
                sh 'docker build -t square-backend:${DEPLOY_ENV}-${BUILD_NUMBER} ./backend'
                sh 'docker build -t square-frontend:${DEPLOY_ENV}-${BUILD_NUMBER} ./frontend'
                sh 'docker build -t square-worker:${DEPLOY_ENV}-${BUILD_NUMBER} ./worker'
            }
        }

        stage('Push and Deploy') {
            when {
                expression { env.DEPLOY_ENV in ['dev', 'prod'] }
            }
            steps {
                withCredentials([
                    usernamePassword(credentialsId: "${env.ACR_CREDENTIALS_ID}", usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS'),
                    usernamePassword(credentialsId: "${env.AZURE_SP_CREDENTIALS_ID}", usernameVariable: 'AZ_SP_APP_ID', passwordVariable: 'AZ_SP_PASSWORD')
                ]) {
                    sh '''
                        set -e
                        source deploy/${DEPLOY_ENV}.env

                        az login --service-principal -u "$AZ_SP_APP_ID" -p "$AZ_SP_PASSWORD" --tenant "$AZURE_TENANT_ID"

                        ACR_LOGIN_SERVER="$AZURE_ACR_NAME.azurecr.io"
                        IMAGE_TAG="${DEPLOY_ENV}-${BUILD_NUMBER}"

                        docker tag square-backend:${DEPLOY_ENV}-${BUILD_NUMBER} $ACR_LOGIN_SERVER/square-backend:$IMAGE_TAG
                        docker tag square-frontend:${DEPLOY_ENV}-${BUILD_NUMBER} $ACR_LOGIN_SERVER/square-frontend:$IMAGE_TAG
                        docker tag square-worker:${DEPLOY_ENV}-${BUILD_NUMBER} $ACR_LOGIN_SERVER/square-worker:$IMAGE_TAG

                        echo "$ACR_PASS" | docker login $ACR_LOGIN_SERVER -u "$ACR_USER" --password-stdin
                        docker push $ACR_LOGIN_SERVER/square-backend:$IMAGE_TAG
                        docker push $ACR_LOGIN_SERVER/square-frontend:$IMAGE_TAG
                        docker push $ACR_LOGIN_SERVER/square-worker:$IMAGE_TAG

                        az webapp config container set --name $AZURE_BACKEND_APP --resource-group $AZURE_RESOURCE_GROUP --docker-custom-image-name $ACR_LOGIN_SERVER/square-backend:$IMAGE_TAG --docker-registry-server-url https://$ACR_LOGIN_SERVER --docker-registry-server-user "$ACR_USER" --docker-registry-server-password "$ACR_PASS"
                        az webapp config container set --name $AZURE_FRONTEND_APP --resource-group $AZURE_RESOURCE_GROUP --docker-custom-image-name $ACR_LOGIN_SERVER/square-frontend:$IMAGE_TAG --docker-registry-server-url https://$ACR_LOGIN_SERVER --docker-registry-server-user "$ACR_USER" --docker-registry-server-password "$ACR_PASS"

                        az webapp restart --name $AZURE_BACKEND_APP --resource-group $AZURE_RESOURCE_GROUP
                        az webapp restart --name $AZURE_FRONTEND_APP --resource-group $AZURE_RESOURCE_GROUP
                    '''
                }
            }
        }
    }
}
