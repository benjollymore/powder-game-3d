"""Binary64 external mechanics contract; no pressure/stress or particle walls."""
import math
from tools.feasibility.momentum_reference import (Particle,Node,ZERO,add,sub,scale,cross,dot,particle_to_grid,grid_to_particle,particle_totals,grid_totals,stencil)


def mechanics_step(particles,dx,shape,dt,method,gravity,plane,origin):
    if not math.isfinite(dt) or dt<=0:raise ValueError('Positive finite timestep required')
    for p in particles:
        stencil(p.position,dx,shape)
        if plane is not None and p.position[1]<plane:raise ValueError('Invalid initial half-space')
    grid=particle_to_grid(particles,dx,shape,method)
    before_grid=grid_totals(grid,dx,origin)
    before_particles=particle_totals(particles,dx,origin)
    after={};nodes=[]
    # Ten vec4 records mirror the tiny GPU's committed ledger layout.
    totals=[[0.]*4 for _ in range(10)]
    for index,node in grid.items():
        m=node.mass;v=node.velocity;dv=scale(gravity,dt)
        vg=add(v,dv);vw=vg
        selected=plane is not None and index[1]*dx<=plane and vg[1]<0
        if selected:vw=(vg[0],0.,vg[2])
        jg=scale(sub(vg,v),m);jw=scale(sub(vw,vg),m)
        jg_req=scale(gravity,m*dt);jw_req=(0.,-m*vg[1],0.) if selected else ZERO
        wg=.5*m*(dot(vg,vg)-dot(v,v));ww=.5*m*(dot(vw,vw)-dot(vg,vg))
        wg_req=dot(v,jg_req)+.5*m*dot(dv,dv);ww_req=-.5*m*vg[1]**2 if selected else 0.
        r=sub(scale(index,dx),origin)
        tg,tw=cross(r,jg),cross(r,jw)
        for row,values in enumerate([(*jg,wg),(*jg_req,wg_req),(*jw,ww),(*jw_req,ww_req)]):
            for a in range(4):totals[row][a]+=values[a]
        for row,values in [(4,tg),(5,tw),(6,cross(r,jg_req)),(7,cross(r,jw_req))]:
            for a in range(3):totals[row][a]+=values[a]
        totals[4][3]+=math.sqrt(dot(jg,jg))+math.sqrt(dot(jw,jw))
        totals[5][3]+=math.sqrt(dot(tg,tg))+math.sqrt(dot(tw,tw))
        totals[8][0]+=abs(wg)+abs(ww)
        after[index]=Node(m,vw)
        nodes.append(dict(index=index,mass=m,before=v,gravity=vg,after=vw,selected=selected,jg=jg,jw=jw,wg=wg,ww=ww))
    mapped=grid_to_particle(particles,after,dx,shape,method)
    candidates=[Particle(add(p.position,scale(p.velocity,dt)),p.velocity,p.mass,p.affine) for p in mapped]
    admitted=True;reason=0
    for p in candidates:
        try:stencil(p.position,dx,shape)
        except ValueError:admitted=False;reason=1;break
        if plane is not None and p.position[1]<plane:admitted=False;reason=4;break
    after_grid=grid_totals(after,dx,origin);after_particles=particle_totals(candidates,dx,origin)
    totals[6][3]=before_grid['kinetic_energy']-before_particles['kinetic_energy']
    totals[7][3]=after_particles['kinetic_energy']-after_grid['kinetic_energy']
    totals[9]=[before_particles['kinetic_energy'],before_grid['kinetic_energy'],after_grid['kinetic_energy'],after_particles['kinetic_energy']]
    return (candidates if admitted else list(particles)),totals,nodes,admitted,reason
