% System kinematics of the bodies for the system
%
% Please cite the following paper when using this for multilink cable
% robots:
% D. Lau, D. Oetomo, and S. K. Halgamuge, "Generalized Modeling of
% Multilink Cable-Driven Manipulators with Arbitrary Routing Using the
% Cable-Routing Matrix," IEEE Trans. Robot., vol. 29, no. 5, pp. 1102?1113,
% Oct. 2013.
%
% Author        : Darwin LAU
% Created       : 2011
% Description    :
%    Data structure that represents the kinematics of the bodies of the
% system, encapsulated within an array of BodyKinematics object. Also
% provides global matrices for the entire rigid body kinematics system.
classdef SystemKinematicsBodies < handle
    properties (SetAccess = protected)
        bodies                  % Cell array of BodyKinematics objects

        % Generalised coordinates of the system
        q
        q_dot
        connectivityGraph       % p x p connectivity matrix, if (i,j) = 1 means link i-1 is the parent of link j
        bodiesPathGraph         % p x p matrix that governs how to track to particular bodies, (i,j) = 1 means that to get to link j we must pass through link i

        % Operational Space coordinates of the system
        y
        y_dot
        y_ddot
        
        
        % These matrices should probably be computed as needed (dependent
        % variable), but if it is a commonly used matrix (i.e. accessed
        % multiple times even if the system state does not change) then
        % storing it would be more efficient. However this means that
        % update must be performed through this class' update function and
        % not on the body's update directly. This makes sense since just
        % updating one body without updating the others would cause
        % inconsistency anyway.
        S                       % S matrix representing relationship between relative body velocities (joint) and generalised coordinates velocities
        S_dot                   % Derivative of S
        P                       % 6p x 6p matrix representing mapping between absolute body velocities (CoG) and relative body velocities (joint)
        W                       % W = P*S : 6p x n matrix representing mapping \dot{\mathbf{x}} = W \dot{\mathbf{q}}
        J                       % J matrix representing relationship between generalised coordinate velocities and operational space coordinates
        J_dot                   % Derivative of J
        T                       % Projection of operational coordinates

        % Absolute CoM velocities and accelerations (linear and angular)
        x_dot                   % Absolute velocities
        x_ddot                  % Absolute accelerations (x_ddot = W(q)*q_ddot + C_a(q,q_dot))
        C_a                     % Relationship between body and joint accelerations \ddot{\mathbf{x}} = W \ddot{\mathbf{q}} + C_a

        numDofs
        numDofVars
        numOPDofs
    end

    properties (Dependent)
        numLinks
        q_default
        q_dot_default
        q_ddot_default
        q_lb
        q_ub
        % Generalised coordinates time derivative (for special cases q_dot does not equal q_deriv)
        q_deriv
    end
    
    properties
        q_ddot
    end

    methods
        function b = SystemKinematicsBodies(bodies)
            num_dofs = 0;
            num_dof_vars = 0;
            num_op_dofs = 0;
            for k = 1:length(bodies)
                num_dofs = num_dofs + bodies{k}.numDofs;
                num_dof_vars = num_dof_vars + bodies{k}.numDofVars;
            end
            b.bodies = bodies;
            b.numDofs = num_dofs;
            b.numDofVars = num_dof_vars;
            b.numOPDofs = num_op_dofs;

            b.connectivityGraph = zeros(b.numLinks, b.numLinks);
            b.bodiesPathGraph = zeros(b.numLinks, b.numLinks);
            b.S = zeros(6*b.numLinks, b.numDofs);
            b.P = zeros(6*b.numLinks, 6*b.numLinks);
            b.W = zeros(6*b.numLinks, b.numDofs);
            b.T = MatrixOperations.Initialise(0,6*b.numLinks,0);

            % Connects the objects of the system and create the
            % connectivity and body path graphs
            b.formConnectiveMap();
        end

        % Update the kinematics of the body kinematics for the entire
        % system using the generalised coordinates, velocity and
        % acceleration. This update function should also be called to
        % update the entire system, rather than calling the update function
        % for each body directly.
        function update(obj, q, q_dot, q_ddot)
            % Assign q, q_dot, q_ddot
            obj.q = q;
            obj.q_dot = q_dot;
            obj.q_ddot = q_ddot;
            is_symbolic = isa(q, 'sym');

            % Update each body first
            index_vars = 1;
            index_dofs = 1;
            for k = 1:obj.numLinks
                q_k = q(index_vars:index_vars+obj.bodies{k}.joint.numVars-1);
                q_dot_k = q_dot(index_dofs:index_dofs+obj.bodies{k}.joint.numDofs-1);
                q_ddot_k = q_ddot(index_dofs:index_dofs+obj.bodies{k}.joint.numDofs-1);
                obj.bodies{k}.update(q_k, q_dot_k, q_ddot_k);
                index_vars = index_vars + obj.bodies{k}.joint.numVars;
                index_dofs = index_dofs + obj.bodies{k}.joint.numDofs;
            end

            % Now the global system updates
            % Set bodies kinematics (rotation matrices)
            for k = 1:obj.numLinks
                parent_link_num = obj.bodies{k}.parentLinkId;
                assert(parent_link_num < k, 'Problem with numbering of links with parent and child');

                % Determine rotation matrix
                % Determine joint location
                if parent_link_num > 0
                    obj.bodies{k}.R_0k = obj.bodies{parent_link_num}.R_0k*obj.bodies{k}.joint.R_pe;
                    obj.bodies{k}.r_OP = obj.bodies{k}.joint.R_pe.'*(obj.bodies{parent_link_num}.r_OP + obj.bodies{k}.r_Parent + obj.bodies{k}.joint.r_rel);
                else
                    obj.bodies{k}.R_0k = obj.bodies{k}.joint.R_pe;
                    obj.bodies{k}.r_OP = obj.bodies{k}.joint.R_pe.'*(obj.bodies{k}.r_Parent + obj.bodies{k}.joint.r_rel);
                end
                % Determine absolute position of COG
                obj.bodies{k}.r_OG  = obj.bodies{k}.r_OP + obj.bodies{k}.r_G;
                % Determine absolute position of link's ending position
                obj.bodies{k}.r_OPe = obj.bodies{k}.r_OP + obj.bodies{k}.r_Pe;
                % Determine absolute position of the operational space
                if(~isempty(obj.bodies{k}.r_y))
                    obj.bodies{k}.r_Oy  = obj.bodies{k}.r_OP + obj.bodies{k}.r_y;
                end
            end
            
            % Now determine the operational space vector y
            obj.y = MatrixOperations.Initialise(obj.numOPDofs,1,is_symbolic); l = 1;
            for k = 1:obj.numLinks
                if(~isempty(obj.bodies{k}.op_space))
                    n_y = obj.bodies{k}.numOPDofs;
                    obj.y(l:l+n_y-1) = obj.bodies{k}.op_space.extractOPSpace(obj.bodies{k}.r_Oy,obj.bodies{k}.R_0k);
                    l = l + n_y;                    
                end
            end
            
            % Set S (joint state matrix) and S_dot
            index_dofs = 1;
            obj.S = MatrixOperations.Initialise(6*obj.numLinks,obj.numDofs,is_symbolic);
            obj.S_dot = MatrixOperations.Initialise(6*obj.numLinks,obj.numDofs,is_symbolic);
            for k = 1:obj.numLinks
                obj.S(6*k-5:6*k, index_dofs:index_dofs+obj.bodies{k}.joint.numDofs-1) = obj.bodies{k}.joint.S;
                obj.S_dot(6*k-5:6*k, index_dofs:index_dofs+obj.bodies{k}.joint.numDofs-1) = obj.bodies{k}.joint.S_dot;
                index_dofs = index_dofs + obj.bodies{k}.joint.numDofs;
            end

            % Set P (relationship with joint propagation)
            obj.P = MatrixOperations.Initialise(6*obj.numLinks,6*obj.numLinks,is_symbolic);
            for k = 1:obj.numLinks
                body_k = obj.bodies{k};
                for a = 1:k
                    body_a = obj.bodies{a};
                    R_ka = body_k.R_0k.'*body_a.R_0k;
                    Pak = obj.bodiesPathGraph(a,k)*[R_ka*body_a.joint.R_pe.' -R_ka*MatrixOperations.SkewSymmetric(-body_a.r_OP + R_ka.'*body_k.r_OG); ...
                        zeros(3,3) R_ka];
                    obj.P(6*k-5:6*k, 6*a-5:6*a) = Pak;
                end
            end
            
            % Set Q (relationship with joint propagation for operational space)
            Q = MatrixOperations.Initialise(6*obj.numLinks,6*obj.numLinks,is_symbolic);
            for k = 1:obj.numLinks
                body_k = obj.bodies{k};
                for a = 1:k
                    body_a = obj.bodies{a};
                    R_ka = body_k.R_0k.'*body_a.R_0k;
                    Qak = [body_k.R_0k,zeros(3);zeros(3),body_k.R_0k]*(obj.bodiesPathGraph(a,k)*[R_ka*body_a.joint.R_pe.' -R_ka*MatrixOperations.SkewSymmetric(-body_a.r_OP + R_ka.'*body_k.r_Oy); ...
                        zeros(3,3) R_ka]);
                    Q(6*k-5:6*k, 6*a-5:6*a) = Qak;
                end
            end

            % W = P*S
            obj.W = obj.P*obj.S;
            % Determine x_dot
            obj.x_dot = obj.W*obj.q_dot;
            % Extract absolute velocities
            for k = 1:obj.numLinks
                obj.bodies{k}.v_OG = obj.x_dot(6*k-5:6*k-3);
                obj.bodies{k}.w = obj.x_dot(6*k-2:6*k);
            end
            % J = T*Q*S
            obj.J = obj.T*Q*obj.S;
            % Determine y_dot
            obj.y_dot = obj.J*obj.q_dot;            

            % Determine x_ddot
            ang_mat = MatrixOperations.Initialise(6*obj.numLinks,6*obj.numLinks,is_symbolic);
            for k = 1:obj.numLinks
                kp = obj.bodies{k}.parentLinkId;
                if (kp > 0)
                    w_kp = obj.bodies{kp}.w;
                else
                    w_kp = zeros(3,1);
                end
                w_k = obj.bodies{k}.w;
                ang_mat(6*k-5:6*k, 6*k-5:6*k) = [2*MatrixOperations.SkewSymmetric(w_kp) zeros(3,3); zeros(3,3) MatrixOperations.SkewSymmetric(w_k)];
            end

            obj.C_a = obj.P*obj.S_dot*obj.q_dot + obj.P*ang_mat*obj.S*obj.q_dot;
            for k = 1:obj.numLinks
                for a = 1:k
                    ap = obj.bodies{a}.parentLinkId;
                    if (ap > 0 && obj.bodiesPathGraph(a,k))
                        obj.C_a(6*k-5:6*k-3) = obj.C_a(6*k-5:6*k-3) + obj.bodies{k}.R_0k.'*obj.bodies{ap}.R_0k*cross(obj.bodies{ap}.w, cross(obj.bodies{ap}.w, obj.bodies{a}.r_Parent + obj.bodies{a}.joint.r_rel));
                    end
                end
                obj.C_a(6*k-5:6*k-3) = obj.C_a(6*k-5:6*k-3) + cross(obj.bodies{k}.w, cross(obj.bodies{k}.w, obj.bodies{k}.r_G));
            end
            obj.x_ddot = obj.P*obj.S*obj.q_ddot + obj.C_a;
            
            % Determine J_dot
            temp_j_dot = Q*obj.S_dot + Q*ang_mat*obj.S;            
            for k = 1:obj.numLinks
                for a = 1:k
                    ap = obj.bodies{a}.parentLinkId;
                    if (ap > 0 && obj.bodiesPathGraph(a,k))
                        temp_j_dot(6*k-5:6*k-3,:) = temp_j_dot(6*k-5:6*k-3,:) - ...
                            obj.bodies{k}.R_0k*obj.bodies{k}.R_0k.'*obj.bodies{ap}.R_0k*MatrixOperations.SkewSymmetric(obj.bodies{ap}.w)*MatrixOperations.SkewSymmetric(obj.bodies{a}.r_Parent + obj.bodies{a}.joint.r_rel)*obj.W(6*ap-2:6*ap,:);
                    end
                end
                temp_j_dot(6*k-5:6*k-3,:) = temp_j_dot(6*k-5:6*k-3,:) - obj.bodies{k}.R_0k*MatrixOperations.SkewSymmetric(obj.bodies{k}.w)*MatrixOperations.SkewSymmetric(obj.bodies{k}.r_y)*obj.W(6*k-2:6*k,:);
            end
            obj.J_dot = obj.T*temp_j_dot;
            obj.y_ddot = obj.J_dot*q_dot + obj.J*obj.q_ddot;

            % Extract absolute accelerations
            for k = 1:obj.numLinks
                obj.bodies{k}.a_OG = obj.x_ddot(6*k-5:6*k-3);
                obj.bodies{k}.w_dot = obj.x_ddot(6*k-2:6*k);
            end
        end

        % Supporting function to connect all of the parent and child bodies
        function formConnectiveMap(obj)
            for k = 1:obj.numLinks
                obj.connectBodies(obj.bodies{k}.parentLinkId, k, obj.bodies{k}.r_Parent);
            end
        end

        % Supporting function to connect a particular child to a parent
        function connectBodies(obj, parent_link_num, child_link_num, r_parent_loc)
            assert(parent_link_num < child_link_num, 'Parent link number must be smaller than child');
            assert(~isempty(obj.bodies{child_link_num}), 'Child link does not exist');
            if parent_link_num > 0
                assert(~isempty(obj.bodies{parent_link_num}), 'Parent link does not exist');
            end

            obj.bodiesPathGraph(child_link_num, child_link_num) = 1;
            child_link = obj.bodies{child_link_num};
            if parent_link_num == 0
                parent_link = [];
            else
                parent_link = obj.bodies{parent_link_num};
            end
            child_link.addParent(parent_link, r_parent_loc);
            obj.connectivityGraph(parent_link_num+1, child_link_num) = 1;

            if (parent_link_num > 0)
                obj.bodiesPathGraph(parent_link_num, child_link_num) = 1;
                obj.bodiesPathGraph(:, child_link_num) = obj.bodiesPathGraph(:, child_link_num) | obj.bodiesPathGraph(:, parent_link_num);
            end
        end
        
        function q = qIntegrate(obj, q0, q_dot, dt)
            index_vars = 1;
            q = zeros(size(q0));
            for k = 1:obj.numLinks
                q(index_vars:index_vars+obj.bodies{k}.joint.numVars-1) = obj.bodies{k}.joint.QIntegrate(q0, q_dot, dt);
                index_vars = index_vars + obj.bodies{k}.joint.numVars;
            end
        end

        function n = get.numLinks(obj)
            n = length(obj.bodies);
        end

        function q = get.q_default(obj)
            q = zeros(obj.numDofVars, 1);
            index_vars = 1;
            for k = 1:obj.numLinks
                q(index_vars:index_vars+obj.bodies{k}.joint.numVars-1) = obj.bodies{k}.joint.q_default;
                index_vars = index_vars + obj.bodies{k}.joint.numVars;
            end
        end

        function q_dot = get.q_dot_default(obj)
            q_dot = zeros(obj.numDofs, 1);
            index_dofs = 1;
            for k = 1:obj.numLinks
                q_dot(index_dofs:index_dofs+obj.bodies{k}.joint.numDofs-1) = obj.bodies{k}.joint.q_dot_default;
                index_dofs = index_dofs + obj.bodies{k}.joint.numDofs;
            end
        end

        function q_ddot = get.q_ddot_default(obj)
            q_ddot = zeros(obj.numDofs, 1);
            index_dofs = 1;
            for k = 1:obj.numLinks
                q_ddot(index_dofs:index_dofs+obj.bodies{k}.joint.numDofs-1) = obj.bodies{k}.joint.q_ddot_default;
                index_dofs = index_dofs + obj.bodies{k}.joint.numDofs;
            end
        end
        
        function q_lb = get.q_lb(obj)
            q_lb = zeros(obj.numDofVars, 1);
            index_vars = 1;
            for k = 1:obj.numLinks
                q_lb(index_vars:index_vars+obj.bodies{k}.joint.numVars-1) = obj.bodies{k}.joint.q_lb;
                index_vars = index_vars + obj.bodies{k}.joint.numVars;
            end
        end
        
        function q_ub = get.q_ub(obj)
            q_ub = zeros(obj.numDofVars, 1);
            index_vars = 1;
            for k = 1:obj.numLinks
                q_ub(index_vars:index_vars+obj.bodies{k}.joint.numVars-1) = obj.bodies{k}.joint.q_ub;
                index_vars = index_vars + obj.bodies{k}.joint.numVars;
            end
        end
        
        function q_deriv = get.q_deriv(obj)
            q_deriv = zeros(obj.numDofVars, 1);
            index_vars = 1;
            for k = 1:obj.numLinks
                q_deriv(index_vars:index_vars+obj.bodies{k}.joint.numVars-1) = obj.bodies{k}.joint.q_deriv;
                index_vars = index_vars + obj.bodies{k}.joint.numVars;
            end
        end  
        
        function loadOpXmlObj(obj,op_space_xmlobj)
            %% Load the op space
            assert(strcmp(op_space_xmlobj.getNodeName, 'op_set'), 'Root element should be <op_set>');
            % Go into the cable set
            allOPItems = op_space_xmlobj.getChildNodes;
            
            num_ops = allOPItems.getLength;
            % Creates all of the operational spaces first first
            for k = 1:num_ops
                % Java uses 0 indexing
                currentOPItem = allOPItems.item(k-1);

                type = char(currentOPItem.getNodeName);
                if (strcmp(type, 'position'))
                    op_space = OpPosition.LoadXmlObj(currentOPItem);
                else
                    error('Unknown link type: %s', type);
                end
                parent_link = op_space.link;
                obj.bodies{parent_link}.attachOPSpace(op_space);
                % Should add some protection to ensure that one OP_Space
                % per link
            end
            num_op_dofs = 0;
            for k = 1:length(obj.bodies)
                num_op_dofs = num_op_dofs + obj.bodies{k}.numOPDofs;
            end
            obj.numOPDofs = num_op_dofs;
            
            obj.T = MatrixOperations.Initialise(obj.numOPDofs,6*obj.numLinks,0);
            l = 1; 
            for k = 1:length(obj.bodies)
                if(~isempty(obj.bodies{k}.op_space))
                    n_y = obj.bodies{k}.numOPDofs;
                    obj.T(l:l+n_y-1,6*k-5:6*k) = obj.bodies{k}.op_space.getSelectionMatrix();
                    l = l + n_y;
                end
            end
        end
    end

    methods (Static)
        function b = LoadXmlObj(body_prop_xmlobj)
            %% Load the body
            assert(strcmp(body_prop_xmlobj.getNodeName, 'links'), 'Root element should be <links>');
            
%             allLinkItems = body_prop_xmlobj.getChildNodes;
            allLinkItems = body_prop_xmlobj.getElementsByTagName('link_rigid');

            num_links = allLinkItems.getLength;
            links = cell(1,num_links);

            % Creates all of the links first
            for k = 1:num_links
                % Java uses 0 indexing
                currentLinkItem = allLinkItems.item(k-1);

                num_k = str2double(currentLinkItem.getAttribute('num'));
                assert(num_k == k, sprintf('Link number does not correspond to its order, order: %d, specified num: %d ', k, num_k));

                type = char(currentLinkItem.getNodeName);
                if (strcmp(type, 'link_rigid'))
                    links{k} = BodyKinematicsRigid.LoadXmlObj(currentLinkItem);
                else
                    error('Unknown link type: %s', type);
                end
            end

            % Create the actual object to return
            b = SystemKinematicsBodies(links);
        end
    end
end
