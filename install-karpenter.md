# EKS Karpenter 安装指南

## 1. 安装IAM Role and IAM Policy and Queue

设置环境变量：

```bash
export KARPENTER_NAMESPACE="karpenter"
export KARPENTER_VERSION="1.3.3"
export K8S_VERSION="1.30"
export TEMPOUT="$(mktemp)"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

通过CloudFormation部署所需资源：

```bash
curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml  > "${TEMPOUT}" \
&& aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"
```

## 2. 验证oidc是否存在，没有则创建它

检查OIDC是否存在：

```bash
aws eks describe-cluster --name $CLUSTER_NAME | grep oidc 
```

创建OIDC提供者：

```bash
eksctl utils associate-iam-oidc-provider --cluster ${CLUSTER_NAME} --approve
```

## 3. 添加节点角色aws-auth映射，有节点角色的可以加入集群

```bash
eksctl create iamidentitymapping \
  --username system:node:{{EC2PrivateDNSName}} \
  --cluster  ${CLUSTER_NAME} \
  --arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME} \
  --group system:bootstrappers \
  --group system:nodes
```

## 4. 创建 iamserviceaccount

```bash
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME --name karpenter --namespace karpenter \
  --attach-policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/KarpenterControllerPolicy-$CLUSTER_NAME \
  --approve
```

如果有异常可以考虑，可以考虑删除后重新创建：

```bash
eksctl delete iamserviceaccount \
  --cluster ${CLUSTER_NAME} \
  --name karpenter \
  --namespace karpenter
```

## 5. 之前没有运行过 Amazon EC2 spot 实例，请运行下面命令

```bash
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

## 6. 安装Karpenter

```bash
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter \
  --set nodeSelector."alpha\.eksctl\.io/nodegroup-name"=ng-7dff9970
