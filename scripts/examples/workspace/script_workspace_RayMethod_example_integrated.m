
clc;  close all; warning off; clear all;

% Set up the model  
% model_config    =   ModelConfig('2 DoF VSD');   %    spatial7cable   BMArm_paper   BMArm_paper
% cable_set_id    =   'basic';
% modelObj        =   model_config.getModel(cable_set_id);
% nsegvar= [2500;2500];      % number of discritization on each axis. if the user desire to ignore discritization on one axis its corresponding discritiaztion number can be set to zero

model_config    =   DevModelConfig('spatial7cable');   %    spatial7cable     
cable_set_id    =   'original';
modelObj        =   model_config.getModel(cable_set_id);
nsegvar= [3, 3, 3, 6, 6, 6]';

q_begin         =   modelObj.bodyModel.q_min; q_end = modelObj.bodyModel.q_max; 
uGrid           =   UniformGrid(q_begin,q_end,(q_end-q_begin)./(nsegvar-1),'step_size');
% Workspace settings and conditions
% w_condition     =   {WorkspaceRayConditionBase.CreateWorkspaceRayCondition(WorkspaceRayConditionType.WRENCH_CLOSURE,2)};
w_condition     =   {WorkspaceRayConditionBase.CreateWorkspaceRayCondition(WorkspaceRayConditionType.INTERFERENCE,2)};
opt             =   RayWorkspaceSimulatorOptions(false,false);
% Start the simulation
disp('Start Setup Simulation');
wsim            =   RayWorkspaceSimulator(modelObj,uGrid,opt);

% Run the simulation
disp('Start Running Simulation');
wsim.run(w_condition,[])
