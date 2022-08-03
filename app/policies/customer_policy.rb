class CustomerPolicy < ApplicationPolicy

    def index?
        super || user &&
          RecordPermission.exists_for_user?(user, :brand) ||
          RecordPermission.exists_for_user?(user, :operator)
    end

    def promos_presented_list?
        user&.admin? || user &&
          RecordPermission.exists_for_user?(user, :brand) ||
          RecordPermission.exists_for_user?(user, :operator)
        end

    def answered_survey_questions_list?
        user&.admin? || user &&
          RecordPermission.exists_for_user?(user, :brand) ||
          RecordPermission.exists_for_user?(user, :operator)
    end

    def destroy?
        user&.admin? || user && (
          (RecordPermission.exists_for_user?(user, :operator, :admin)) ||
          (RecordPermission.exists_for_user?(user, :operator, :edit))
        )
    end

    def delete_list?
        user&.admin? || user && (
          (RecordPermission.exists_for_user?(user, :operator, :admin)) ||
          (RecordPermission.exists_for_user?(user, :operator, :edit))
        )
    end

    def delete_all?
        user&.admin? || user && (
          (RecordPermission.exists_for_user?(user, :operator, :admin)) ||
          (RecordPermission.exists_for_user?(user, :operator, :edit))
        )
    end

    def print?
        user&.admin? || user &&
          RecordPermission.exists_for_user?(user, :brand) ||
          RecordPermission.exists_for_user?(user, :operator)
    end

    def export?
        user&.admin? || user &&
          RecordPermission.exists_for_user?(user, :brand) ||
          RecordPermission.exists_for_user?(user, :operator)
    end

    def update_customer_status?
        user&.admin? || user && (
          (RecordPermission.exists_for_user?(user, :operator, :admin)) ||
          (RecordPermission.exists_for_user?(user, :operator, :edit))
        )
    end

    def create_vouchers?
        user&.admin?
    end

    def register_multiple_users_on_operators?
        user&.admin?
    end

    def import_customers?
        user&.admin? || user && (
          (RecordPermission.exists_for_user?(user, :operator, :admin)) ||
          (RecordPermission.exists_for_user?(user, :operator, :edit))
        )
        end

    def import?
        user&.admin? || user && (
          (RecordPermission.exists_for_user?(user, :operator, :admin)) ||
          (RecordPermission.exists_for_user?(user, :operator, :edit))
        )
    end

    def deduction?
        user&.admin?
    end

    def add_user_to_list?
        user&.admin?
    end

    class Scope
        attr_reader :user, :scope

        def initialize(user, scope)
            @user = user
            @scope = scope
        end

        def resolve
            if !user
                scope.none
            else
                scope.available_for_user(user)
            end
        end
    end


end
