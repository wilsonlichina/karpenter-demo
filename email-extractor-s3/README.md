# 名片电子邮件地址提取服务

本应用利用 AWS Bedrock 和 Claude 3.5 Sonnet 模型从 S3 存储桶中的名片图片提取电子邮件地址信息。

## 功能特点

- 从 S3 存储桶读取名片图片
- 利用 Bedrock 和 Claude 3.5 Sonnet 模型提取图片中的电子邮件地址
- 提供 RESTful API 接口查询结果
- 部署在 EKS 集群上，使用 AWS S3 CSI Driver 实现持久化存储
- 利用 IAM 服务账号进行身份验证
- **支持多架构部署 (amd64 和 arm64)**
- **复用 game-2048-group ALB Ingress**

## 部署前提条件

- 已有一个运行中的名为 `my-cc-cluster` 的 EKS 集群
- AWS CLI 已配置并拥有足够权限
- kubectl 已配置并可连接到集群
- Docker 已安装（用于构建镜像）
- 一个存有名片图片的 S3 存储桶 `business-card-email-extractor`
- 已创建名为 `email-extractor-sa` 的 IAM 服务账号（见下方步骤）

## 系统架构

```
┌─────────────┐     ┌─────────────┐     ┌────────────────┐
│ Kubernetes  │     │    Flask    │     │    Bedrock     │
│  Service    │────▶│ Application │────▶│ Claude 3.5     │
│             │     │             │     │    Sonnet      │
└─────────────┘     └─────────────┘     └────────────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │     S3      │
                    │  (存储桶)   │
                    │             │
                    └─────────────┘
```

## 部署步骤

### 步骤 1: 配置环境变量

设置部署所需的环境变量：

```bash
export NAMESPACE="email-extractor"
export CLUSTER_NAME="my-cc-cluster"
export AWS_DEFAULT_REGION="us-east-1"
export S3_BUCKET_NAME="business-card-email-extractor"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export EMAIL_EXTRACTOR_POLICY_ARN="arn:aws:iam::595115466597:policy/eks-business-card-extractor-policy"
export IMAGE_NAME="email-extractor"
export IMAGE_TAG="latest"
export ECR_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${IMAGE_NAME}"
```

### 步骤 2: 配置与集群的连接

确保能够连接到 EKS 集群：

```bash
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_DEFAULT_REGION
```

### 步骤 3: 创建 IAM ServiceAccount

创建命名空间（如果不存在）：

```bash
kubectl create namespace $NAMESPACE
```

创建 IAM ServiceAccount：

```bash
eksctl create iamserviceaccount \
    --name email-extractor-sa \
    --namespace $NAMESPACE \
    --cluster $CLUSTER_NAME \
    --attach-policy-arn $EMAIL_EXTRACTOR_POLICY_ARN \
    --approve \
    --override-existing-serviceaccounts
```

### 步骤 4: 创建 ECR 仓库

如果 ECR 仓库不存在，创建它：

```bash
aws ecr describe-repositories --repository-names $IMAGE_NAME || \
  aws ecr create-repository --repository-name $IMAGE_NAME
```

### 步骤 5: 登录 ECR

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
```

### 步骤 6: 构建并推送多架构 Docker 镜像

设置 Docker buildx 环境:

```bash
# 移除已存在的构建器（如果有）
docker buildx rm multiarch-builder 2>/dev/null || true
# 创建新的构建器实例
docker buildx create --name multiarch-builder --use
```

构建并推送支持 AMD64 和 ARM64 的多架构镜像:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ${ECR_REPO}:${IMAGE_TAG} \
  --push \
  .
```

清理构建器:

```bash
docker buildx rm multiarch-builder
```

### 步骤 7: 应用 Kubernetes 配置

创建命名空间：

```bash
kubectl apply -f k8s/namespace.yaml
```

应用持久卷和持久卷声明：

```bash
kubectl apply -f k8s/persistent-volume.yaml
kubectl apply -f k8s/persistent-volume-claim.yaml
```

应用部署配置（替换环境变量）：

```bash
cat k8s/deployment.yaml | \
  sed "s|\${AWS_ACCOUNT_ID}|$AWS_ACCOUNT_ID|g" | \
  sed "s|\${AWS_REGION}|$AWS_REGION|g" | \
  sed "s|\${S3_BUCKET_NAME}|$S3_BUCKET_NAME|g" | \
  kubectl apply -f -
```

应用服务配置：

```bash
kubectl apply -f k8s/service.yaml
```

应用 Ingress 配置（使用 game-2048-group ALB）：

```bash
kubectl apply -f k8s/ingress.yaml
```

### 步骤 9: 验证部署

检查部署状态：

```bash
kubectl get all -n email-extractor
```

查看应用日志：

```bash
kubectl logs -n email-extractor deployment/email-extractor
```

### 步骤 10: 访问应用

应用可以通过共享的 ALB 访问，路径为 `/email-extractor`。

您也可以通过转发本地端口来测试：

```bash
kubectl port-forward -n email-extractor service/email-extractor 8080:80
```

然后在本地访问 `http://localhost:8080/email-extractor`

## API 使用指南

### 1. 列出可用的图片

```bash
curl http://localhost:8080/list-images
```

可选：通过 prefix 参数过滤：

```bash
curl "http://localhost:8080/list-images?prefix=folder/"
```

### 2. 从图片中提取电子邮件地址

```bash
curl -X POST \
  http://localhost:8080/extract \
  -H "Content-Type: application/json" \
  -d '{"image_key": "path/to/business-card.jpg"}'
```

响应示例：

```json
{
  "emails": ["john.doe@example.com"],
  "image_key": "path/to/business-card.jpg",
  "status": "success"
}
```

### 3. 健康检查

```bash
curl http://localhost:8080/health
```

## 配置说明

应用配置是通过环境变量设置的：

- `S3_BUCKET_NAME` - S3 存储桶名称 (默认: `business-card-email-extractor`)
- `S3_MOUNT_PATH` - S3 挂载路径（默认：`/mnt/s3`）

## 存储结构

应用通过 AWS S3 CSI Driver 将您的 S3 存储桶 `business-card-email-extractor` 挂载为文件系统，使得应用可以像访问本地文件一样访问您的图片文件。持久卷配置使用了静态预置方式，通过以下步骤实现：

1. 创建 PersistentVolume (PV) 资源，指定 S3 CSI 驱动程序与存储桶
2. 创建 PersistentVolumeClaim (PVC) 资源，与 PV 进行绑定
3. 在 Deployment 中引用该 PVC，将其挂载到容器的 `/mnt/s3` 路径

## Kubernetes 配置文件说明

### 持久卷 (PersistentVolume)

持久卷配置定义了如何连接到 S3 存储桶:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: email-extractor-s3-pv
spec:
  capacity:
    storage: 1200Gi # Ignored, required
  accessModes:
    - ReadOnlyMany # 我们只需要读取权限
  persistentVolumeReclaimPolicy: Retain
  storageClassName: "" # 静态预置需要
  claimRef: # 确保只有特定的 PVC 能够绑定此 PV
    namespace: email-extractor
    name: email-extractor-s3-pvc
  mountOptions:
    - allow-delete
    - region us-east-1
  csi:
    driver: s3.csi.aws.com # S3 CSI 驱动
    volumeHandle: email-extractor-s3-volume
    volumeAttributes:
      bucketName: business-card-email-extractor
```

### 持久卷声明 (PersistentVolumeClaim)

持久卷声明与上面创建的持久卷绑定:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: email-extractor-s3-pvc
  namespace: email-extractor
spec:
  accessModes:
    - ReadOnlyMany
  storageClassName: "" # 静态预置需要
  resources:
    requests:
      storage: 1200Gi
  volumeName: email-extractor-s3-pv
```

## 故障排查

1. **Pod 启动失败**

查看 Pod 状态：

```bash
kubectl describe pod -n email-extractor
```

2. **无法连接到 API**

验证服务是否运行：

```bash
kubectl get svc -n email-extractor
```

3. **S3 挂载问题**

检查 S3 挂载点是否正确配置：

```bash
kubectl exec -it -n email-extractor $(kubectl get pods -n email-extractor -o name | head -1) -- ls -la /mnt/s3
```

4. **ECR 推送问题**

如果 Docker 镜像推送失败，确认 AWS 凭证是否有效：

```bash
aws sts get-caller-identity
```

## 安全考虑

- 应用使用 IAM 服务账号进行身份验证
- S3 存储桶访问仅限于所需操作
- Kubernetes 资源使用命名空间隔离
- 容器以非 root 用户运行

## 维护与更新

**重新构建和部署**:

如果修改了应用代码，需要重新构建和部署：

```bash
# 重新构建 Docker 镜像
docker build -t $IMAGE_NAME:$IMAGE_TAG -f Dockerfile .

# 标记并推送到 ECR
docker tag $IMAGE_NAME:$IMAGE_TAG $ECR_REPO:$IMAGE_TAG
docker push $ECR_REPO:$IMAGE_TAG

# 重启 Deployment 以拉取新镜像
kubectl rollout restart deployment/email-extractor -n email-extractor
```

**清理资源**：

```bash
kubectl delete namespace email-extractor
```
# 名片电子邮件地址提取服务

本应用利用 AWS Bedrock 和 Claude 3.5 Sonnet 模型从 S3 存储桶中的名片图片提取电子邮件地址信息。

## 功能特点

- 从 S3 存储桶读取名片图片
- 利用 Bedrock 和 Claude 3.5 Sonnet 模型提取图片中的电子邮件地址
- 提供 RESTful API 接口查询结果
- 部署在 EKS 集群上，使用 AWS S3 CSI Driver 实现持久化存储
- 利用 IAM 服务账号进行身份验证

## 部署前提条件

- 已有一个运行中的名为 `my-cc-cluster` 的 EKS 集群
- AWS CLI 已配置并拥有足够权限
- kubectl 已配置并可连接到集群
- Docker 已安装（用于构建镜像）
- 一个存有名片图片的 S3 存储桶 `business-card-email-extractor`
- 已创建名为 `email-extractor-sa` 的 IAM 服务账号（见下方步骤）

## 系统架构

```
┌─────────────┐     ┌─────────────┐     ┌────────────────┐
│ Kubernetes  │     │    Flask    │     │    Bedrock     │
│  Service    │────▶│ Application │────▶│ Claude 3.5     │
│             │     │             │     │    Sonnet      │
└─────────────┘     └─────────────┘     └────────────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │     S3      │
                    │  (存储桶)   │
                    │             │
                    └─────────────┘
```

## 部署步骤

### 步骤 1: 配置环境变量

设置部署所需的环境变量：

```bash
export NAMESPACE="email-extractor"
export CLUSTER_NAME="my-cc-cluster"
export AWS_DEFAULT_REGION="us-east-1"
export S3_BUCKET_NAME="business-card-email-extractor"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export EMAIL_EXTRACTOR_POLICY_ARN="arn:aws:iam::595115466597:policy/eks-business-card-extractor-policy"
export IMAGE_NAME="email-extractor"
export IMAGE_TAG="latest"
export ECR_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${IMAGE_NAME}"
```

### 步骤 2: 配置与集群的连接

确保能够连接到 EKS 集群：

```bash
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_DEFAULT_REGION
```

### 步骤 3: 创建 IAM ServiceAccount

创建命名空间（如果不存在）：

```bash
kubectl create namespace $NAMESPACE
```

创建 IAM ServiceAccount：

```bash
eksctl create iamserviceaccount \
    --name email-extractor-sa \
    --namespace $NAMESPACE \
    --cluster $CLUSTER_NAME \
    --attach-policy-arn $EMAIL_EXTRACTOR_POLICY_ARN \
    --approve \
    --override-existing-serviceaccounts
```

### 步骤 4: 创建 ECR 仓库

如果 ECR 仓库不存在，创建它：

```bash
aws ecr describe-repositories --repository-names $IMAGE_NAME || \
  aws ecr create-repository --repository-name $IMAGE_NAME
```

### 步骤 5: 登录 ECR

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
```

### 步骤 6: 构建 Docker 镜像

```bash
docker build -t $IMAGE_NAME:$IMAGE_TAG -f Dockerfile .
```

### 步骤 7: 标记并推送镜像到 ECR

```bash
docker tag $IMAGE_NAME:$IMAGE_TAG $ECR_REPO:$IMAGE_TAG
docker push $ECR_REPO:$IMAGE_TAG
```

### 步骤 8: 应用 Kubernetes 配置

创建命名空间：

```bash
kubectl apply -f k8s/namespace.yaml
```

应用持久卷和持久卷声明：

```bash
kubectl apply -f k8s/persistent-volume.yaml
kubectl apply -f k8s/persistent-volume-claim.yaml
```

应用部署配置（替换环境变量）：

```bash
cat k8s/deployment.yaml | \
  sed "s|\${AWS_ACCOUNT_ID}|$AWS_ACCOUNT_ID|g" | \
  sed "s|\${S3_BUCKET_NAME}|$S3_BUCKET_NAME|g" | \
  kubectl apply -f -
```

应用服务配置：

```bash
kubectl apply -f k8s/service.yaml
```

### 步骤 9: 验证部署

检查部署状态：

```bash
kubectl get all -n email-extractor
```

查看应用日志：

```bash
kubectl logs -n email-extractor deployment/email-extractor
```

### 步骤 10: 访问应用

转发本地端口到服务：

```bash
kubectl port-forward -n email-extractor service/email-extractor 8080:80
```

现在可以通过 `http://localhost:8080` 访问 API。

## API 使用指南

### 1. 列出可用的图片

```bash
curl http://localhost:8080/list-images
```

可选：通过 prefix 参数过滤：

```bash
curl "http://localhost:8080/list-images?prefix=folder/"
```

### 2. 从图片中提取电子邮件地址

```bash
curl -X POST \
  http://localhost:8080/extract \
  -H "Content-Type: application/json" \
  -d '{"image_key": "path/to/business-card.jpg"}'
```

响应示例：

```json
{
  "emails": ["john.doe@example.com"],
  "image_key": "path/to/business-card.jpg",
  "status": "success"
}
```

### 3. 健康检查

```bash
curl http://localhost:8080/health
```

## 配置说明

应用配置是通过环境变量设置的：

- `S3_BUCKET_NAME` - S3 存储桶名称 (默认: `business-card-email-extractor`)
- `S3_MOUNT_PATH` - S3 挂载路径（默认：`/mnt/s3`）

## 存储结构

应用通过 AWS S3 CSI Driver 将您的 S3 存储桶 `business-card-email-extractor` 挂载为文件系统，使得应用可以像访问本地文件一样访问您的图片文件。持久卷配置使用了静态预置方式，通过以下步骤实现：

1. 创建 PersistentVolume (PV) 资源，指定 S3 CSI 驱动程序与存储桶
2. 创建 PersistentVolumeClaim (PVC) 资源，与 PV 进行绑定
3. 在 Deployment 中引用该 PVC，将其挂载到容器的 `/mnt/s3` 路径

## Kubernetes 配置文件说明

### 持久卷 (PersistentVolume)

持久卷配置定义了如何连接到 S3 存储桶:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: email-extractor-s3-pv
spec:
  capacity:
    storage: 1200Gi # Ignored, required
  accessModes:
    - ReadOnlyMany # 我们只需要读取权限
  persistentVolumeReclaimPolicy: Retain
  storageClassName: "" # 静态预置需要
  claimRef: # 确保只有特定的 PVC 能够绑定此 PV
    namespace: email-extractor
    name: email-extractor-s3-pvc
  mountOptions:
    - allow-delete
    - region us-east-1
  csi:
    driver: s3.csi.aws.com # S3 CSI 驱动
    volumeHandle: email-extractor-s3-volume
    volumeAttributes:
      bucketName: business-card-email-extractor
```

### 持久卷声明 (PersistentVolumeClaim)

持久卷声明与上面创建的持久卷绑定:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: email-extractor-s3-pvc
  namespace: email-extractor
spec:
  accessModes:
    - ReadOnlyMany
  storageClassName: "" # 静态预置需要
  resources:
    requests:
      storage: 1200Gi
  volumeName: email-extractor-s3-pv
```

## 故障排查

1. **Pod 启动失败**

查看 Pod 状态：

```bash
kubectl describe pod -n email-extractor
```

2. **无法连接到 API**

验证服务是否运行：

```bash
kubectl get svc -n email-extractor
```

3. **S3 挂载问题**

检查 S3 挂载点是否正确配置：

```bash
kubectl exec -it -n email-extractor $(kubectl get pods -n email-extractor -o name | head -1) -- ls -la /mnt/s3
```

4. **ECR 推送问题**

如果 Docker 镜像推送失败，确认 AWS 凭证是否有效：

```bash
aws sts get-caller-identity
```

## 安全考虑

- 应用使用 IAM 服务账号进行身份验证
- S3 存储桶访问仅限于所需操作
- Kubernetes 资源使用命名空间隔离
- 容器以非 root 用户运行

## 维护与更新

**重新构建和部署**:

如果修改了应用代码，需要重新构建和部署：

```bash
# 重新构建 Docker 镜像
docker build -t $IMAGE_NAME:$IMAGE_TAG -f Dockerfile .

# 标记并推送到 ECR
docker tag $IMAGE_NAME:$IMAGE_TAG $ECR_REPO:$IMAGE_TAG
docker push $ECR_REPO:$IMAGE_TAG

# 重启 Deployment 以拉取新镜像
kubectl rollout restart deployment/email-extractor -n email-extractor
```

**清理资源**：

```bash
