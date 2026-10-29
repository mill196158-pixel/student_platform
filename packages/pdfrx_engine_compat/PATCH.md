# pdfrx_engine compatibility patch
Upstream: https://github.com/espresso3389/pdfrx/tree/master/packages/pdfrx_engine
Source: pub.dev pdfrx_engine 0.4.4. Original LICENSE retained.
Only runtime patch: capture a final non-null activeCache before the asynchronous
read closure in pdf_file_cache.dart, preserving promotion across await.
Later 0.4.6 fixes nullable access, but requires archive 4, incompatible with
current excel/archive 3 dependency constraints. Root and Admin share this copy.
Remove the override after a compatible upstream dependency upgrade is verified.
Workspace resolution directive removed for standalone path resolution.
