# Object Storage Service API

Use Object Storage and Archive Storage APIs to manage buckets, objects, and related resources. For more information, see [Overview of Object Storage](https://docs.oracle.com/iaas/Content/Object/Concepts/objectstorageoverview.htm) and [Overview of Archive Storage](https://docs.oracle.com/iaas/Content/Archive/Concepts/archivestorageoverview.htm).

## ObjectStorageClient
 - Parameters to be implemented:
     - `proxySettings`
    - `retryConfig`

## Bucket
- [CreateBucket](https://docs.oracle.com/en-us/iaas/api/#/en/objectstorage/20160918/Bucket/CreateBucket) 
    - Parameters implemented:
        - `namespaceName`
        - `opc-client-request-id`

- [GetBucket](https://docs.oracle.com/en-us/iaas/api/#/en/objectstorage/20160918/Bucket/GetBucket) 
    - Parameters implemented:
        - `namespaceName`
        - `bucketName`
     - Parameters to be implemented:
        - `retryConfig`
        - `ifMatch`
        - `ifNoneMatch`
        - `opcClientRequestId`
        - `fields`

- [ListBuckets](https://docs.oracle.com/en-us/iaas/api/#/en/objectstorage/20160918/Bucket/ListBuckets) 
    - Parameters implemented:
        - `namespaceName`
        - `compartmentId`
        - `opc-client-request-id`
    - Parameters to be implemented:
        - `limit`
        - `page`
        - `fileds`

## Namespace
- [GetNamespace](https://docs.oracle.com/en-us/iaas/api/#/en/objectstorage/20160918/Namespace/GetNamespace) 
    - Parameters implemented:
        - `opc-client-request-id`
        - `compartmentId`
        

