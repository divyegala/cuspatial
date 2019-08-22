"""
A toy example to demonstrate how to convert python arrays into cuSpatial inputs,
invoke the GPU accelerated directed Hausdorff distance computing function in cuSpatial,
convert the results back to python array(s) again to be feed into scipy clustering APIs
For the toy example, by desgin, both AgglomerativeClustering and DBSCAN cluster the 2nd and thrid 
trajectories into one cluster while leaving the first trajectory as the sconed cluster. 
Note: make sure cudf_dev conda environment is activated
"""

import numpy as np
import time
from cudf.dataframe import columnops
import cuspatial.bindings.spatial as gis
from scipy.spatial.distance import directed_hausdorff
from sklearn.cluster import AgglomerativeClustering,DBSCAN

in_trajs=[]
in_trajs.append(np.array([[1,0],[2,1],[3,2],[5,3],[7,1]]))
in_trajs.append(np.array([[0,3],[2,5],[3,6],[6,5]]))
in_trajs.append(np.array([[1,4],[3,7],[6,4]]))
out_trajs = np.concatenate([np.asarray(traj) for traj in in_trajs],0)
py_x=np.array(out_trajs[:,0])
py_y=np.array(out_trajs[:,1])
py_cnt = []
for traj in in_trajs:
 py_cnt.append(len(traj))
pnt_x=columnops.as_column(py_x,dtype=np.float64)
pnt_y=columnops.as_column(py_y,dtype=np.float64)
cnt=columnops.as_column(py_cnt,dtype=np.int32)
distance=gis.cpp_directed_hausdorff_distance(pnt_x,pnt_y,cnt)

num_set=len(cnt)
matrix=distance.data.to_array().reshape(num_set,num_set)

#clustering using AgglomerativeClustering
agg1= AgglomerativeClustering(n_clusters=2, affinity='precomputed', linkage = 'average')
label1=agg1.fit(matrix)
print("AgglomerativeClustering results={}".format(label1.labels_))

#clustering using DBSCAN; as the minimum distanance is ~1.4, 
#using eps=1.5 will generate the same two clasters as AgglomerativeClustering
agg2=DBSCAN(eps=1.5,min_samples=1,metric='precomputed')
label2=agg2.fit(matrix)
print("DBSCAN clustering results={}".format(label2.labels_))
