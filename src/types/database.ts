export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      access_grants: {
        Row: {
          applied_at: string | null
          applied_user_id: string | null
          created_at: string
          email: string
          employee_id: string | null
          entity_id: string | null
          granted_at: string
          granted_by: string | null
          id: string
          location_id: string | null
          revoke_reason: string | null
          revoked_at: string | null
          revoked_by: string | null
          role: Database["public"]["Enums"]["user_role"]
          status: string
          updated_at: string
        }
        Insert: {
          applied_at?: string | null
          applied_user_id?: string | null
          created_at?: string
          email: string
          employee_id?: string | null
          entity_id?: string | null
          granted_at?: string
          granted_by?: string | null
          id?: string
          location_id?: string | null
          revoke_reason?: string | null
          revoked_at?: string | null
          revoked_by?: string | null
          role: Database["public"]["Enums"]["user_role"]
          status?: string
          updated_at?: string
        }
        Update: {
          applied_at?: string | null
          applied_user_id?: string | null
          created_at?: string
          email?: string
          employee_id?: string | null
          entity_id?: string | null
          granted_at?: string
          granted_by?: string | null
          id?: string
          location_id?: string | null
          revoke_reason?: string | null
          revoked_at?: string | null
          revoked_by?: string | null
          role?: Database["public"]["Enums"]["user_role"]
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "access_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "access_grants_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "access_grants_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
        ]
      }
      advance_repayments: {
        Row: {
          advance_id: string
          amount: number
          created_at: string
          id: string
          period_id: string
          record_id: string
        }
        Insert: {
          advance_id: string
          amount: number
          created_at?: string
          id?: string
          period_id: string
          record_id: string
        }
        Update: {
          advance_id?: string
          amount?: number
          created_at?: string
          id?: string
          period_id?: string
          record_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "advance_repayments_advance_id_fkey"
            columns: ["advance_id"]
            isOneToOne: false
            referencedRelation: "salary_advances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "advance_repayments_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "advance_repayments_record_id_fkey"
            columns: ["record_id"]
            isOneToOne: false
            referencedRelation: "payroll_records"
            referencedColumns: ["id"]
          },
        ]
      }
      app_settings: {
        Row: {
          key: string
          updated_at: string
          updated_by: string | null
          value: boolean
        }
        Insert: {
          key: string
          updated_at?: string
          updated_by?: string | null
          value: boolean
        }
        Update: {
          key?: string
          updated_at?: string
          updated_by?: string | null
          value?: boolean
        }
        Relationships: []
      }
      attendance_adjustments: {
        Row: {
          actor_id: string
          actor_role: Database["public"]["Enums"]["user_role"]
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_reason: string | null
          id: string
          payable_shift_record_id: string
          proposed_minutes: number
          reason: string
          status: string
        }
        Insert: {
          actor_id: string
          actor_role: Database["public"]["Enums"]["user_role"]
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_reason?: string | null
          id?: string
          payable_shift_record_id: string
          proposed_minutes: number
          reason: string
          status?: string
        }
        Update: {
          actor_id?: string
          actor_role?: Database["public"]["Enums"]["user_role"]
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_reason?: string | null
          id?: string
          payable_shift_record_id?: string
          proposed_minutes?: number
          reason?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "attendance_adjustments_actor_id_fkey"
            columns: ["actor_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_adjustments_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_adjustments_payable_shift_record_id_fkey"
            columns: ["payable_shift_record_id"]
            isOneToOne: false
            referencedRelation: "payable_shift_records"
            referencedColumns: ["id"]
          },
        ]
      }
      attendance_records: {
        Row: {
          clock_in_at: string
          clock_out_at: string | null
          corrected: boolean
          corrected_at: string | null
          corrected_by: string | null
          correction_reason: string | null
          created_at: string
          employee_id: string
          entity_id: string
          id: string
          location_id: string
          original_clock_in_at: string | null
          original_clock_out_at: string | null
          shift_id: string | null
          updated_at: string
        }
        Insert: {
          clock_in_at: string
          clock_out_at?: string | null
          corrected?: boolean
          corrected_at?: string | null
          corrected_by?: string | null
          correction_reason?: string | null
          created_at?: string
          employee_id: string
          entity_id: string
          id?: string
          location_id: string
          original_clock_in_at?: string | null
          original_clock_out_at?: string | null
          shift_id?: string | null
          updated_at?: string
        }
        Update: {
          clock_in_at?: string
          clock_out_at?: string | null
          corrected?: boolean
          corrected_at?: string | null
          corrected_by?: string | null
          correction_reason?: string | null
          created_at?: string
          employee_id?: string
          entity_id?: string
          id?: string
          location_id?: string
          original_clock_in_at?: string | null
          original_clock_out_at?: string | null
          shift_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "attendance_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_records_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_records_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_records_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_log: {
        Row: {
          action: string | null
          changed_at: string | null
          changed_by: string | null
          employee_id: string | null
          entity_id: string | null
          id: string
          location_id: string | null
          new_value: Json | null
          old_value: Json | null
          record_id: string
          table_name: string
        }
        Insert: {
          action?: string | null
          changed_at?: string | null
          changed_by?: string | null
          employee_id?: string | null
          entity_id?: string | null
          id?: string
          location_id?: string | null
          new_value?: Json | null
          old_value?: Json | null
          record_id: string
          table_name: string
        }
        Update: {
          action?: string | null
          changed_at?: string | null
          changed_by?: string | null
          employee_id?: string | null
          entity_id?: string | null
          id?: string
          location_id?: string | null
          new_value?: Json | null
          old_value?: Json | null
          record_id?: string
          table_name?: string
        }
        Relationships: [
          {
            foreignKeyName: "audit_log_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_log_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_log_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
        ]
      }
      candidate_files: {
        Row: {
          candidate_id: string
          entity_id: string
          file_type: string
          id: string
          storage_path: string
          uploaded_at: string
          uploaded_by: string | null
          visible_to_interviewers: boolean
        }
        Insert: {
          candidate_id: string
          entity_id: string
          file_type: string
          id?: string
          storage_path: string
          uploaded_at?: string
          uploaded_by?: string | null
          visible_to_interviewers?: boolean
        }
        Update: {
          candidate_id?: string
          entity_id?: string
          file_type?: string
          id?: string
          storage_path?: string
          uploaded_at?: string
          uploaded_by?: string | null
          visible_to_interviewers?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "candidate_files_candidate_id_fkey"
            columns: ["candidate_id"]
            isOneToOne: false
            referencedRelation: "candidates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "candidate_files_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      candidates: {
        Row: {
          contact_email: string | null
          contact_phone: string | null
          created_at: string
          created_by: string | null
          entity_id: string
          full_name: string
          id: string
          location_id: string | null
          resume_url: string | null
          source: string
          status: string
          updated_at: string
        }
        Insert: {
          contact_email?: string | null
          contact_phone?: string | null
          created_at?: string
          created_by?: string | null
          entity_id: string
          full_name: string
          id?: string
          location_id?: string | null
          resume_url?: string | null
          source?: string
          status?: string
          updated_at?: string
        }
        Update: {
          contact_email?: string | null
          contact_phone?: string | null
          created_at?: string
          created_by?: string | null
          entity_id?: string
          full_name?: string
          id?: string
          location_id?: string | null
          resume_url?: string | null
          source?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "candidates_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "candidates_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
        ]
      }
      compensation_components: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          effective_from: string
          effective_to: string | null
          employee_id: string
          id: string
          kind: string
          label: string
          monthly_amount: number
          prorate: boolean
          reason: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          effective_from: string
          effective_to?: string | null
          employee_id: string
          id?: string
          kind: string
          label: string
          monthly_amount: number
          prorate?: boolean
          reason?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          effective_from?: string
          effective_to?: string | null
          employee_id?: string
          id?: string
          kind?: string
          label?: string
          monthly_amount?: number
          prorate?: boolean
          reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "compensation_components_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      compensation_versions: {
        Row: {
          basic_monthly: number | null
          created_at: string
          created_by: string | null
          effective_from: string
          employee_id: string
          hourly_rate: number | null
          id: string
          overtime_eligible: boolean
          pay_type: string
          reason: string | null
        }
        Insert: {
          basic_monthly?: number | null
          created_at?: string
          created_by?: string | null
          effective_from: string
          employee_id: string
          hourly_rate?: number | null
          id?: string
          overtime_eligible?: boolean
          pay_type: string
          reason?: string | null
        }
        Update: {
          basic_monthly?: number | null
          created_at?: string
          created_by?: string | null
          effective_from?: string
          employee_id?: string
          hourly_rate?: number | null
          id?: string
          overtime_eligible?: boolean
          pay_type?: string
          reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "compensation_versions_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      data_retention_policies: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          created_at: string
          created_by: string | null
          disposal_method: string
          entity_id: string
          id: string
          is_approved: boolean
          legal_basis: string | null
          retention_years: number
          table_name: string
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          created_by?: string | null
          disposal_method?: string
          entity_id: string
          id?: string
          is_approved?: boolean
          legal_basis?: string | null
          retention_years: number
          table_name: string
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          created_by?: string | null
          disposal_method?: string
          entity_id?: string
          id?: string
          is_approved?: boolean
          legal_basis?: string | null
          retention_years?: number
          table_name?: string
        }
        Relationships: [
          {
            foreignKeyName: "data_retention_policies_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_acknowledgements: {
        Row: {
          acknowledged_at: string
          acknowledged_by: string
          employee_id: string
          id: string
          onboarding_instance_id: string | null
          policy_id: string
          policy_key: string
          policy_version: string
        }
        Insert: {
          acknowledged_at?: string
          acknowledged_by: string
          employee_id: string
          id?: string
          onboarding_instance_id?: string | null
          policy_id: string
          policy_key: string
          policy_version: string
        }
        Update: {
          acknowledged_at?: string
          acknowledged_by?: string
          employee_id?: string
          id?: string
          onboarding_instance_id?: string | null
          policy_id?: string
          policy_key?: string
          policy_version?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_acknowledgements_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_acknowledgements_onboarding_instance_id_fkey"
            columns: ["onboarding_instance_id"]
            isOneToOne: false
            referencedRelation: "onboarding_instances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_acknowledgements_policy_id_fkey"
            columns: ["policy_id"]
            isOneToOne: false
            referencedRelation: "onboarding_policies"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_availability: {
        Row: {
          day_of_week: number
          employee_id: string
          end_time: string | null
          id: string
          is_available: boolean
          start_time: string | null
        }
        Insert: {
          day_of_week: number
          employee_id: string
          end_time?: string | null
          id?: string
          is_available?: boolean
          start_time?: string | null
        }
        Update: {
          day_of_week?: number
          employee_id?: string
          end_time?: string | null
          id?: string
          is_available?: boolean
          start_time?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employee_availability_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_change_requests: {
        Row: {
          decided_at: string | null
          decided_by: string | null
          decision_reason: string | null
          employee_id: string
          field_name: string
          id: string
          new_value: string
          old_value: string | null
          reason: string | null
          requested_at: string
          status: string
        }
        Insert: {
          decided_at?: string | null
          decided_by?: string | null
          decision_reason?: string | null
          employee_id: string
          field_name: string
          id?: string
          new_value: string
          old_value?: string | null
          reason?: string | null
          requested_at?: string
          status?: string
        }
        Update: {
          decided_at?: string | null
          decided_by?: string | null
          decision_reason?: string | null
          employee_id?: string
          field_name?: string
          id?: string
          new_value?: string
          old_value?: string | null
          reason?: string | null
          requested_at?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_change_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_compensation: {
        Row: {
          employee_id: string
          holiday_multiplier: number
          overtime_multiplier: number
          pay_rate: number | null
          pay_type: string
          updated_at: string | null
        }
        Insert: {
          employee_id: string
          holiday_multiplier?: number
          overtime_multiplier?: number
          pay_rate?: number | null
          pay_type?: string
          updated_at?: string | null
        }
        Update: {
          employee_id?: string
          holiday_multiplier?: number
          overtime_multiplier?: number
          pay_rate?: number | null
          pay_type?: string
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employee_compensation_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_contract_acceptances: {
        Row: {
          accepted_at: string
          accepted_by: string
          document_id: string
          document_version: number
          employee_id: string
          id: string
          onboarding_instance_id: string
        }
        Insert: {
          accepted_at?: string
          accepted_by: string
          document_id: string
          document_version: number
          employee_id: string
          id?: string
          onboarding_instance_id: string
        }
        Update: {
          accepted_at?: string
          accepted_by?: string
          document_id?: string
          document_version?: number
          employee_id?: string
          id?: string
          onboarding_instance_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_contract_acceptances_document_id_fkey"
            columns: ["document_id"]
            isOneToOne: false
            referencedRelation: "employee_documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_contract_acceptances_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_contract_acceptances_onboarding_instance_id_fkey"
            columns: ["onboarding_instance_id"]
            isOneToOne: false
            referencedRelation: "onboarding_instances"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_document_requirements: {
        Row: {
          created_at: string
          created_by: string | null
          doc_type: Database["public"]["Enums"]["document_type"]
          document_id: string | null
          employee_id: string
          id: string
          status: string
          updated_at: string
          waived_at: string | null
          waived_by: string | null
          waived_reason: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          doc_type: Database["public"]["Enums"]["document_type"]
          document_id?: string | null
          employee_id: string
          id?: string
          status?: string
          updated_at?: string
          waived_at?: string | null
          waived_by?: string | null
          waived_reason?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          doc_type?: Database["public"]["Enums"]["document_type"]
          document_id?: string | null
          employee_id?: string
          id?: string
          status?: string
          updated_at?: string
          waived_at?: string | null
          waived_by?: string | null
          waived_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employee_document_requirements_document_id_fkey"
            columns: ["document_id"]
            isOneToOne: false
            referencedRelation: "employee_documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_document_requirements_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_documents: {
        Row: {
          archived_at: string | null
          archived_by: string | null
          created_at: string
          doc_type: Database["public"]["Enums"]["document_type"]
          employee_id: string
          expiry_date: string | null
          id: string
          is_current: boolean
          notes: string | null
          rejection_reason: string | null
          review_status: string
          reviewed_at: string | null
          reviewed_by: string | null
          storage_path: string
          submitted_at: string
          submitted_by: string | null
          supersedes_document_id: string | null
          updated_at: string
          upload_confirmed: boolean
          upload_confirmed_at: string | null
          upload_method: string | null
          uploaded_at: string | null
          uploaded_by: string | null
          version_number: number
        }
        Insert: {
          archived_at?: string | null
          archived_by?: string | null
          created_at?: string
          doc_type: Database["public"]["Enums"]["document_type"]
          employee_id: string
          expiry_date?: string | null
          id?: string
          is_current?: boolean
          notes?: string | null
          rejection_reason?: string | null
          review_status?: string
          reviewed_at?: string | null
          reviewed_by?: string | null
          storage_path: string
          submitted_at?: string
          submitted_by?: string | null
          supersedes_document_id?: string | null
          updated_at?: string
          upload_confirmed?: boolean
          upload_confirmed_at?: string | null
          upload_method?: string | null
          uploaded_at?: string | null
          uploaded_by?: string | null
          version_number?: number
        }
        Update: {
          archived_at?: string | null
          archived_by?: string | null
          created_at?: string
          doc_type?: Database["public"]["Enums"]["document_type"]
          employee_id?: string
          expiry_date?: string | null
          id?: string
          is_current?: boolean
          notes?: string | null
          rejection_reason?: string | null
          review_status?: string
          reviewed_at?: string | null
          reviewed_by?: string | null
          storage_path?: string
          submitted_at?: string
          submitted_by?: string | null
          supersedes_document_id?: string | null
          updated_at?: string
          upload_confirmed?: boolean
          upload_confirmed_at?: string | null
          upload_method?: string | null
          uploaded_at?: string | null
          uploaded_by?: string | null
          version_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "employee_documents_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_documents_supersedes_document_id_fkey"
            columns: ["supersedes_document_id"]
            isOneToOne: false
            referencedRelation: "employee_documents"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_identity_documents: {
        Row: {
          bank_iban: string | null
          bank_name: string | null
          employee_id: string
          health_card_no: string | null
          labor_card_no: string | null
          national_id_no: string | null
          passport_no: string | null
          updated_at: string
          visa_no: string | null
        }
        Insert: {
          bank_iban?: string | null
          bank_name?: string | null
          employee_id: string
          health_card_no?: string | null
          labor_card_no?: string | null
          national_id_no?: string | null
          passport_no?: string | null
          updated_at?: string
          visa_no?: string | null
        }
        Update: {
          bank_iban?: string | null
          bank_name?: string | null
          employee_id?: string
          health_card_no?: string | null
          labor_card_no?: string | null
          national_id_no?: string | null
          passport_no?: string | null
          updated_at?: string
          visa_no?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employee_identity_documents_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_immigration_cases: {
        Row: {
          close_reason: string | null
          closed_at: string | null
          closed_by: string | null
          employee_id: string
          entity_id: string
          id: string
          mohre_person_code: string | null
          notes: string | null
          onboarding_instance_id: string | null
          opened_at: string
          opened_by: string | null
          status: string
          track: string
          uid_number: string | null
          updated_at: string
          visa_file_number: string | null
          work_permit_number: string | null
        }
        Insert: {
          close_reason?: string | null
          closed_at?: string | null
          closed_by?: string | null
          employee_id: string
          entity_id: string
          id?: string
          mohre_person_code?: string | null
          notes?: string | null
          onboarding_instance_id?: string | null
          opened_at?: string
          opened_by?: string | null
          status?: string
          track: string
          uid_number?: string | null
          updated_at?: string
          visa_file_number?: string | null
          work_permit_number?: string | null
        }
        Update: {
          close_reason?: string | null
          closed_at?: string | null
          closed_by?: string | null
          employee_id?: string
          entity_id?: string
          id?: string
          mohre_person_code?: string | null
          notes?: string | null
          onboarding_instance_id?: string | null
          opened_at?: string
          opened_by?: string | null
          status?: string
          track?: string
          uid_number?: string | null
          updated_at?: string
          visa_file_number?: string | null
          work_permit_number?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employee_immigration_cases_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_immigration_cases_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_immigration_cases_onboarding_instance_id_fkey"
            columns: ["onboarding_instance_id"]
            isOneToOne: false
            referencedRelation: "onboarding_instances"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_immigration_steps: {
        Row: {
          case_id: string
          completed_at: string | null
          due_date: string | null
          expiry_date: string | null
          fee_amount: number | null
          fee_paid_by: string | null
          id: string
          is_blocking: boolean
          label: string
          notes: string | null
          reference_number: string | null
          sort_order: number
          started_at: string | null
          status: string
          step_key: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          case_id: string
          completed_at?: string | null
          due_date?: string | null
          expiry_date?: string | null
          fee_amount?: number | null
          fee_paid_by?: string | null
          id?: string
          is_blocking?: boolean
          label: string
          notes?: string | null
          reference_number?: string | null
          sort_order?: number
          started_at?: string | null
          status?: string
          step_key: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          case_id?: string
          completed_at?: string | null
          due_date?: string | null
          expiry_date?: string | null
          fee_amount?: number | null
          fee_paid_by?: string | null
          id?: string
          is_blocking?: boolean
          label?: string
          notes?: string | null
          reference_number?: string | null
          sort_order?: number
          started_at?: string | null
          status?: string
          step_key?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employee_immigration_steps_case_id_fkey"
            columns: ["case_id"]
            isOneToOne: false
            referencedRelation: "employee_immigration_cases"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_numbering: {
        Row: {
          entity_id: string
          next_value: number
          pad_width: number
          prefix: string
          updated_at: string
        }
        Insert: {
          entity_id: string
          next_value?: number
          pad_width?: number
          prefix?: string
          updated_at?: string
        }
        Update: {
          entity_id?: string
          next_value?: number
          pad_width?: number
          prefix?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_numbering_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: true
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_payment_details: {
        Row: {
          account_name: string | null
          bank_name: string | null
          employee_id: string
          iban: string | null
          id: string
          method: string
          rejection_reason: string | null
          routing_code: string | null
          status: string
          submitted_at: string
          submitted_by: string | null
          verified_at: string | null
          verified_by: string | null
        }
        Insert: {
          account_name?: string | null
          bank_name?: string | null
          employee_id: string
          iban?: string | null
          id?: string
          method: string
          rejection_reason?: string | null
          routing_code?: string | null
          status?: string
          submitted_at?: string
          submitted_by?: string | null
          verified_at?: string | null
          verified_by?: string | null
        }
        Update: {
          account_name?: string | null
          bank_name?: string | null
          employee_id?: string
          iban?: string | null
          id?: string
          method?: string
          rejection_reason?: string | null
          routing_code?: string | null
          status?: string
          submitted_at?: string
          submitted_by?: string | null
          verified_at?: string | null
          verified_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employee_payment_details_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_probation_periods: {
        Row: {
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_effective_date: string | null
          decision_reason: string | null
          employee_id: string
          end_date: string
          id: string
          onboarding_instance_id: string | null
          previous_period_id: string | null
          review_due_date: string
          start_date: string
          status: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_effective_date?: string | null
          decision_reason?: string | null
          employee_id: string
          end_date: string
          id?: string
          onboarding_instance_id?: string | null
          previous_period_id?: string | null
          review_due_date: string
          start_date: string
          status?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_effective_date?: string | null
          decision_reason?: string | null
          employee_id?: string
          end_date?: string
          id?: string
          onboarding_instance_id?: string | null
          previous_period_id?: string | null
          review_due_date?: string
          start_date?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_probation_periods_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_probation_periods_onboarding_instance_id_fkey"
            columns: ["onboarding_instance_id"]
            isOneToOne: false
            referencedRelation: "onboarding_instances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_probation_periods_previous_period_id_fkey"
            columns: ["previous_period_id"]
            isOneToOne: false
            referencedRelation: "employee_probation_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_probation_reviews: {
        Row: {
          comments: string
          created_at: string
          id: string
          probation_period_id: string
          ratings: Json | null
          recommendation: string
          reviewer_id: string
          reviewer_role: string
        }
        Insert: {
          comments: string
          created_at?: string
          id?: string
          probation_period_id: string
          ratings?: Json | null
          recommendation: string
          reviewer_id: string
          reviewer_role: string
        }
        Update: {
          comments?: string
          created_at?: string
          id?: string
          probation_period_id?: string
          ratings?: Json | null
          recommendation?: string
          reviewer_id?: string
          reviewer_role?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_probation_reviews_probation_period_id_fkey"
            columns: ["probation_period_id"]
            isOneToOne: false
            referencedRelation: "employee_probation_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_work_patterns: {
        Row: {
          days_off_mode: string
          days_per_week: number
          employee_id: string
          entity_id: string
          fixed_days_off: number[]
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          days_off_mode: string
          days_per_week: number
          employee_id: string
          entity_id: string
          fixed_days_off?: number[]
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          days_off_mode?: string
          days_per_week?: number
          employee_id?: string
          entity_id?: string
          fixed_days_off?: number[]
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employee_work_patterns_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_work_patterns_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      employees: {
        Row: {
          auth_user_id: string | null
          availability_confirmed_at: string | null
          created_at: string | null
          dob: string | null
          email: string | null
          emergency_contact_name: string | null
          emergency_contact_phone: string | null
          employee_number: string | null
          employment_status:
            | Database["public"]["Enums"]["employee_status"]
            | null
          employment_type: Database["public"]["Enums"]["employment_type"] | null
          entity_id: string
          full_name: string
          gender: string | null
          health_card_exp: string | null
          home_location_id: string | null
          id: string
          join_date: string | null
          labor_card_exp: string | null
          last_working_date: string | null
          nationality: string | null
          notes: string | null
          passport_exp: string | null
          phone: string | null
          photo_url: string | null
          position_id: string | null
          preferred_name: string | null
          probation_end_date: string | null
          reporting_manager_employee_id: string | null
          residential_address: string | null
          updated_at: string | null
          visa_exp: string | null
        }
        Insert: {
          auth_user_id?: string | null
          availability_confirmed_at?: string | null
          created_at?: string | null
          dob?: string | null
          email?: string | null
          emergency_contact_name?: string | null
          emergency_contact_phone?: string | null
          employee_number?: string | null
          employment_status?:
            | Database["public"]["Enums"]["employee_status"]
            | null
          employment_type?:
            | Database["public"]["Enums"]["employment_type"]
            | null
          entity_id: string
          full_name: string
          gender?: string | null
          health_card_exp?: string | null
          home_location_id?: string | null
          id?: string
          join_date?: string | null
          labor_card_exp?: string | null
          last_working_date?: string | null
          nationality?: string | null
          notes?: string | null
          passport_exp?: string | null
          phone?: string | null
          photo_url?: string | null
          position_id?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          reporting_manager_employee_id?: string | null
          residential_address?: string | null
          updated_at?: string | null
          visa_exp?: string | null
        }
        Update: {
          auth_user_id?: string | null
          availability_confirmed_at?: string | null
          created_at?: string | null
          dob?: string | null
          email?: string | null
          emergency_contact_name?: string | null
          emergency_contact_phone?: string | null
          employee_number?: string | null
          employment_status?:
            | Database["public"]["Enums"]["employee_status"]
            | null
          employment_type?:
            | Database["public"]["Enums"]["employment_type"]
            | null
          entity_id?: string
          full_name?: string
          gender?: string | null
          health_card_exp?: string | null
          home_location_id?: string | null
          id?: string
          join_date?: string | null
          labor_card_exp?: string | null
          last_working_date?: string | null
          nationality?: string | null
          notes?: string | null
          passport_exp?: string | null
          phone?: string | null
          photo_url?: string | null
          position_id?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          reporting_manager_employee_id?: string | null
          residential_address?: string | null
          updated_at?: string | null
          visa_exp?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employees_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_home_location_id_fkey"
            columns: ["home_location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_reporting_manager_employee_id_fkey"
            columns: ["reporting_manager_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      entities: {
        Row: {
          code: string | null
          created_at: string | null
          default_currency: string | null
          emirate: string | null
          id: string
          is_active: boolean
          mohre_establishment_id: string | null
          name: string
          payroll_day: number | null
          trade_license_no: string | null
          updated_at: string
        }
        Insert: {
          code?: string | null
          created_at?: string | null
          default_currency?: string | null
          emirate?: string | null
          id?: string
          is_active?: boolean
          mohre_establishment_id?: string | null
          name: string
          payroll_day?: number | null
          trade_license_no?: string | null
          updated_at?: string
        }
        Update: {
          code?: string | null
          created_at?: string | null
          default_currency?: string | null
          emirate?: string | null
          id?: string
          is_active?: boolean
          mohre_establishment_id?: string | null
          name?: string
          payroll_day?: number | null
          trade_license_no?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      interview_feedback: {
        Row: {
          competency_ratings: Json | null
          concerns: string | null
          created_at: string
          id: string
          interview_id: string
          notes: string | null
          recommendation: string | null
          reopen_reason: string | null
          reopened_at: string | null
          reopened_by: string | null
          status: string
          strengths: string | null
          submitted_at: string | null
          submitted_by: string
          updated_at: string
        }
        Insert: {
          competency_ratings?: Json | null
          concerns?: string | null
          created_at?: string
          id?: string
          interview_id: string
          notes?: string | null
          recommendation?: string | null
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          status?: string
          strengths?: string | null
          submitted_at?: string | null
          submitted_by: string
          updated_at?: string
        }
        Update: {
          competency_ratings?: Json | null
          concerns?: string | null
          created_at?: string
          id?: string
          interview_id?: string
          notes?: string | null
          recommendation?: string | null
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          status?: string
          strengths?: string | null
          submitted_at?: string | null
          submitted_by?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "interview_feedback_interview_id_fkey"
            columns: ["interview_id"]
            isOneToOne: true
            referencedRelation: "interviews"
            referencedColumns: ["id"]
          },
        ]
      }
      interview_round_closures: {
        Row: {
          application_id: string
          closed_at: string
          closed_by: string
          id: string
          reason: string
          stage_id: string
        }
        Insert: {
          application_id: string
          closed_at?: string
          closed_by: string
          id?: string
          reason: string
          stage_id: string
        }
        Update: {
          application_id?: string
          closed_at?: string
          closed_by?: string
          id?: string
          reason?: string
          stage_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "interview_round_closures_application_id_fkey"
            columns: ["application_id"]
            isOneToOne: false
            referencedRelation: "job_applications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "interview_round_closures_stage_id_fkey"
            columns: ["stage_id"]
            isOneToOne: false
            referencedRelation: "interview_stages"
            referencedColumns: ["id"]
          },
        ]
      }
      interview_stages: {
        Row: {
          guide: string | null
          id: string
          name: string
          requisition_id: string
          sequence: number
        }
        Insert: {
          guide?: string | null
          id?: string
          name: string
          requisition_id: string
          sequence: number
        }
        Update: {
          guide?: string | null
          id?: string
          name?: string
          requisition_id?: string
          sequence?: number
        }
        Relationships: [
          {
            foreignKeyName: "interview_stages_requisition_id_fkey"
            columns: ["requisition_id"]
            isOneToOne: false
            referencedRelation: "job_requisitions"
            referencedColumns: ["id"]
          },
        ]
      }
      interviews: {
        Row: {
          application_id: string
          cancellation_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          format: string
          id: string
          interviewer_id: string
          meeting_location: string | null
          notes: string | null
          outcome: string
          recorded_at: string | null
          recorded_by: string | null
          rescheduled_from_interview_id: string | null
          scheduled_at: string
          stage_id: string
        }
        Insert: {
          application_id: string
          cancellation_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          format?: string
          id?: string
          interviewer_id: string
          meeting_location?: string | null
          notes?: string | null
          outcome?: string
          recorded_at?: string | null
          recorded_by?: string | null
          rescheduled_from_interview_id?: string | null
          scheduled_at: string
          stage_id: string
        }
        Update: {
          application_id?: string
          cancellation_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          format?: string
          id?: string
          interviewer_id?: string
          meeting_location?: string | null
          notes?: string | null
          outcome?: string
          recorded_at?: string | null
          recorded_by?: string | null
          rescheduled_from_interview_id?: string | null
          scheduled_at?: string
          stage_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "interviews_application_id_fkey"
            columns: ["application_id"]
            isOneToOne: false
            referencedRelation: "job_applications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "interviews_rescheduled_from_interview_id_fkey"
            columns: ["rescheduled_from_interview_id"]
            isOneToOne: false
            referencedRelation: "interviews"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "interviews_stage_id_fkey"
            columns: ["stage_id"]
            isOneToOne: false
            referencedRelation: "interview_stages"
            referencedColumns: ["id"]
          },
        ]
      }
      job_applications: {
        Row: {
          applied_at: string
          candidate_id: string
          id: string
          rejection_reason: string | null
          requisition_id: string
          stage: string
        }
        Insert: {
          applied_at?: string
          candidate_id: string
          id?: string
          rejection_reason?: string | null
          requisition_id: string
          stage?: string
        }
        Update: {
          applied_at?: string
          candidate_id?: string
          id?: string
          rejection_reason?: string | null
          requisition_id?: string
          stage?: string
        }
        Relationships: [
          {
            foreignKeyName: "job_applications_candidate_id_fkey"
            columns: ["candidate_id"]
            isOneToOne: false
            referencedRelation: "candidates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_applications_requisition_id_fkey"
            columns: ["requisition_id"]
            isOneToOne: false
            referencedRelation: "job_requisitions"
            referencedColumns: ["id"]
          },
        ]
      }
      job_requisitions: {
        Row: {
          closed_at: string | null
          closed_by: string | null
          created_at: string
          created_by: string | null
          entity_id: string
          headcount: number
          id: string
          location_id: string
          opened_at: string | null
          opened_by: string | null
          position_id: string
          status: string
        }
        Insert: {
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          created_by?: string | null
          entity_id: string
          headcount?: number
          id?: string
          location_id: string
          opened_at?: string | null
          opened_by?: string | null
          position_id: string
          status?: string
        }
        Update: {
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          created_by?: string | null
          entity_id?: string
          headcount?: number
          id?: string
          location_id?: string
          opened_at?: string | null
          opened_by?: string | null
          position_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "job_requisitions_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_requisitions_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_requisitions_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_accrual_policies: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          carry_forward_cap_days: number | null
          created_at: string
          created_by: string | null
          days_per_period: number
          entity_id: string
          frequency: string
          id: string
          is_approved: boolean
          leave_type_id: string
          max_balance_days: number | null
          policy_start_date: string
          probation_days: number
          rounding: string
          updated_at: string
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          carry_forward_cap_days?: number | null
          created_at?: string
          created_by?: string | null
          days_per_period: number
          entity_id: string
          frequency: string
          id?: string
          is_approved?: boolean
          leave_type_id: string
          max_balance_days?: number | null
          policy_start_date: string
          probation_days?: number
          rounding?: string
          updated_at?: string
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          carry_forward_cap_days?: number | null
          created_at?: string
          created_by?: string | null
          days_per_period?: number
          entity_id?: string
          frequency?: string
          id?: string
          is_approved?: boolean
          leave_type_id?: string
          max_balance_days?: number | null
          policy_start_date?: string
          probation_days?: number
          rounding?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "leave_accrual_policies_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_accrual_policies_leave_type_id_fkey"
            columns: ["leave_type_id"]
            isOneToOne: true
            referencedRelation: "leave_types"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_accrual_runs: {
        Row: {
          balance_after: number
          balance_before: number
          created_at: string
          created_by: string | null
          days_accrued: number
          employee_id: string
          id: string
          leave_type_id: string
          period_key: string
          policy_id: string
        }
        Insert: {
          balance_after: number
          balance_before: number
          created_at?: string
          created_by?: string | null
          days_accrued: number
          employee_id: string
          id?: string
          leave_type_id: string
          period_key: string
          policy_id: string
        }
        Update: {
          balance_after?: number
          balance_before?: number
          created_at?: string
          created_by?: string | null
          days_accrued?: number
          employee_id?: string
          id?: string
          leave_type_id?: string
          period_key?: string
          policy_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "leave_accrual_runs_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_accrual_runs_leave_type_id_fkey"
            columns: ["leave_type_id"]
            isOneToOne: false
            referencedRelation: "leave_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_accrual_runs_policy_id_fkey"
            columns: ["policy_id"]
            isOneToOne: false
            referencedRelation: "leave_accrual_policies"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_balances: {
        Row: {
          balance_days: number
          employee_id: string
          id: string
          leave_type_id: string
          updated_at: string | null
        }
        Insert: {
          balance_days?: number
          employee_id: string
          id?: string
          leave_type_id: string
          updated_at?: string | null
        }
        Update: {
          balance_days?: number
          employee_id?: string
          id?: string
          leave_type_id?: string
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "leave_balances_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_balances_leave_type_id_fkey"
            columns: ["leave_type_id"]
            isOneToOne: false
            referencedRelation: "leave_types"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_requests: {
        Row: {
          balance_reserved: boolean
          cancellation_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          days_requested: number
          decided_at: string | null
          decided_by: string | null
          employee_id: string
          end_date: string
          id: string
          leave_type_id: string
          manager_notes: string | null
          reason: string | null
          requested_at: string | null
          start_date: string
          status: string
        }
        Insert: {
          balance_reserved?: boolean
          cancellation_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          days_requested: number
          decided_at?: string | null
          decided_by?: string | null
          employee_id: string
          end_date: string
          id?: string
          leave_type_id: string
          manager_notes?: string | null
          reason?: string | null
          requested_at?: string | null
          start_date: string
          status?: string
        }
        Update: {
          balance_reserved?: boolean
          cancellation_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          days_requested?: number
          decided_at?: string | null
          decided_by?: string | null
          employee_id?: string
          end_date?: string
          id?: string
          leave_type_id?: string
          manager_notes?: string | null
          reason?: string | null
          requested_at?: string | null
          start_date?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_leave_type_id_fkey"
            columns: ["leave_type_id"]
            isOneToOne: false
            referencedRelation: "leave_types"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_types: {
        Row: {
          accrual_days_per_year: number
          created_at: string | null
          eligibility_notes: string | null
          eligible_gender: string | null
          entity_id: string
          full_pay_days: number | null
          half_pay_days: number | null
          id: string
          is_event_based: boolean
          name: string
          payroll_treatment: string
          requires_approval: boolean
          statutory_reference: string | null
          unpaid_days: number | null
        }
        Insert: {
          accrual_days_per_year?: number
          created_at?: string | null
          eligibility_notes?: string | null
          eligible_gender?: string | null
          entity_id: string
          full_pay_days?: number | null
          half_pay_days?: number | null
          id?: string
          is_event_based?: boolean
          name: string
          payroll_treatment?: string
          requires_approval?: boolean
          statutory_reference?: string | null
          unpaid_days?: number | null
        }
        Update: {
          accrual_days_per_year?: number
          created_at?: string | null
          eligibility_notes?: string | null
          eligible_gender?: string | null
          entity_id?: string
          full_pay_days?: number | null
          half_pay_days?: number | null
          id?: string
          is_event_based?: boolean
          name?: string
          payroll_treatment?: string
          requires_approval?: boolean
          statutory_reference?: string | null
          unpaid_days?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "leave_types_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      location_operating_hours: {
        Row: {
          close_time: string | null
          day_of_week: number
          entity_id: string
          is_closed: boolean
          location_id: string
          open_time: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          close_time?: string | null
          day_of_week: number
          entity_id: string
          is_closed?: boolean
          location_id: string
          open_time?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          close_time?: string | null
          day_of_week?: number
          entity_id?: string
          is_closed?: boolean
          location_id?: string
          open_time?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "location_operating_hours_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "location_operating_hours_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
        ]
      }
      location_staffing_needs: {
        Row: {
          created_at: string
          created_by: string | null
          day_of_week: number | null
          end_time: string
          entity_id: string
          id: string
          location_id: string
          position_id: string | null
          staff_needed: number
          start_time: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          day_of_week?: number | null
          end_time: string
          entity_id: string
          id?: string
          location_id: string
          position_id?: string | null
          staff_needed: number
          start_time: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          day_of_week?: number | null
          end_time?: string
          entity_id?: string
          id?: string
          location_id?: string
          position_id?: string | null
          staff_needed?: number
          start_time?: string
        }
        Relationships: [
          {
            foreignKeyName: "location_staffing_needs_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "location_staffing_needs_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "location_staffing_needs_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
        ]
      }
      locations: {
        Row: {
          address: string | null
          code: string | null
          created_at: string | null
          entity_id: string
          id: string
          is_active: boolean
          name: string
          updated_at: string
        }
        Insert: {
          address?: string | null
          code?: string | null
          created_at?: string | null
          entity_id: string
          id?: string
          is_active?: boolean
          name: string
          updated_at?: string
        }
        Update: {
          address?: string | null
          code?: string | null
          created_at?: string | null
          entity_id?: string
          id?: string
          is_active?: boolean
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "locations_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      notifications: {
        Row: {
          created_at: string
          dedupe_key: string | null
          employee_id: string | null
          entity_id: string
          id: string
          message: string | null
          notification_type: string
          priority: string
          read_at: string | null
          recipient_user_id: string | null
          resolved_at: string | null
          target_id: string | null
          target_type: string | null
          title: string
        }
        Insert: {
          created_at?: string
          dedupe_key?: string | null
          employee_id?: string | null
          entity_id: string
          id?: string
          message?: string | null
          notification_type: string
          priority?: string
          read_at?: string | null
          recipient_user_id?: string | null
          resolved_at?: string | null
          target_id?: string | null
          target_type?: string | null
          title: string
        }
        Update: {
          created_at?: string
          dedupe_key?: string | null
          employee_id?: string | null
          entity_id?: string
          id?: string
          message?: string | null
          notification_type?: string
          priority?: string
          read_at?: string | null
          recipient_user_id?: string | null
          resolved_at?: string | null
          target_id?: string | null
          target_type?: string | null
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "notifications_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      offboarding_cases: {
        Row: {
          close_notes: string | null
          closed_at: string | null
          closed_by: string | null
          created_at: string
          created_by: string | null
          employee_id: string
          entity_id: string
          id: string
          in_probation: boolean
          initiated_by: string
          last_working_date: string
          leaving_uae: boolean
          location_id: string | null
          min_notice_days: number
          notice_date: string
          notice_shortfall_reason: string | null
          reason: string
          row_version: number
          separation_type: string
          settlement_due_date: string
          settlement_payroll_period_id: string | null
          source_exception_id: string | null
          source_onboarding_instance_id: string | null
          status: string
          updated_at: string
        }
        Insert: {
          close_notes?: string | null
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          created_by?: string | null
          employee_id: string
          entity_id: string
          id?: string
          in_probation?: boolean
          initiated_by: string
          last_working_date: string
          leaving_uae?: boolean
          location_id?: string | null
          min_notice_days?: number
          notice_date: string
          notice_shortfall_reason?: string | null
          reason: string
          row_version?: number
          separation_type: string
          settlement_due_date: string
          settlement_payroll_period_id?: string | null
          source_exception_id?: string | null
          source_onboarding_instance_id?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          close_notes?: string | null
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          created_by?: string | null
          employee_id?: string
          entity_id?: string
          id?: string
          in_probation?: boolean
          initiated_by?: string
          last_working_date?: string
          leaving_uae?: boolean
          location_id?: string | null
          min_notice_days?: number
          notice_date?: string
          notice_shortfall_reason?: string | null
          reason?: string
          row_version?: number
          separation_type?: string
          settlement_due_date?: string
          settlement_payroll_period_id?: string | null
          source_exception_id?: string | null
          source_onboarding_instance_id?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "offboarding_cases_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "offboarding_cases_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "offboarding_cases_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "offboarding_cases_settlement_payroll_period_id_fkey"
            columns: ["settlement_payroll_period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "offboarding_cases_source_exception_id_fkey"
            columns: ["source_exception_id"]
            isOneToOne: false
            referencedRelation: "onboarding_exceptions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "offboarding_cases_source_onboarding_instance_id_fkey"
            columns: ["source_onboarding_instance_id"]
            isOneToOne: false
            referencedRelation: "onboarding_instances"
            referencedColumns: ["id"]
          },
        ]
      }
      offboarding_tasks: {
        Row: {
          case_id: string
          completed_at: string | null
          completed_by: string | null
          due_date: string | null
          id: string
          is_required: boolean
          item_key: string
          label: string
          notes: string | null
          owner_role: string
          sort_order: number
          status: string
        }
        Insert: {
          case_id: string
          completed_at?: string | null
          completed_by?: string | null
          due_date?: string | null
          id?: string
          is_required?: boolean
          item_key: string
          label: string
          notes?: string | null
          owner_role: string
          sort_order?: number
          status?: string
        }
        Update: {
          case_id?: string
          completed_at?: string | null
          completed_by?: string | null
          due_date?: string | null
          id?: string
          is_required?: boolean
          item_key?: string
          label?: string
          notes?: string | null
          owner_role?: string
          sort_order?: number
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "offboarding_tasks_case_id_fkey"
            columns: ["case_id"]
            isOneToOne: false
            referencedRelation: "offboarding_cases"
            referencedColumns: ["id"]
          },
        ]
      }
      offers: {
        Row: {
          application_id: string
          converted_employee_id: string | null
          created_at: string
          created_by: string | null
          decided_at: string | null
          decision_reason: string | null
          id: string
          position_id: string
          proposed_salary_amount: number
          proposed_start_date: string
          sent_at: string | null
          sent_by: string | null
          status: string
          updated_at: string
        }
        Insert: {
          application_id: string
          converted_employee_id?: string | null
          created_at?: string
          created_by?: string | null
          decided_at?: string | null
          decision_reason?: string | null
          id?: string
          position_id: string
          proposed_salary_amount: number
          proposed_start_date: string
          sent_at?: string | null
          sent_by?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          application_id?: string
          converted_employee_id?: string | null
          created_at?: string
          created_by?: string | null
          decided_at?: string | null
          decision_reason?: string | null
          id?: string
          position_id?: string
          proposed_salary_amount?: number
          proposed_start_date?: string
          sent_at?: string | null
          sent_by?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "offers_application_id_fkey"
            columns: ["application_id"]
            isOneToOne: true
            referencedRelation: "job_applications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "offers_converted_employee_id_fkey"
            columns: ["converted_employee_id"]
            isOneToOne: true
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "offers_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_checklist_items: {
        Row: {
          completed_at: string | null
          completed_by: string | null
          employee_id: string
          id: string
          is_complete: boolean | null
          item_key: string
          item_label: string
          sort_order: number | null
        }
        Insert: {
          completed_at?: string | null
          completed_by?: string | null
          employee_id: string
          id?: string
          is_complete?: boolean | null
          item_key: string
          item_label: string
          sort_order?: number | null
        }
        Update: {
          completed_at?: string | null
          completed_by?: string | null
          employee_id?: string
          id?: string
          is_complete?: boolean | null
          item_key?: string
          item_label?: string
          sort_order?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_checklist_items_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_exceptions: {
        Row: {
          description: string
          due_date: string | null
          exception_type: string
          id: string
          instance_id: string
          is_blocking: boolean
          owner_role: string
          raised_at: string
          raised_by: string | null
          resolution: string | null
          resolved_at: string | null
          resolved_by: string | null
          status: string
        }
        Insert: {
          description: string
          due_date?: string | null
          exception_type: string
          id?: string
          instance_id: string
          is_blocking?: boolean
          owner_role: string
          raised_at?: string
          raised_by?: string | null
          resolution?: string | null
          resolved_at?: string | null
          resolved_by?: string | null
          status?: string
        }
        Update: {
          description?: string
          due_date?: string | null
          exception_type?: string
          id?: string
          instance_id?: string
          is_blocking?: boolean
          owner_role?: string
          raised_at?: string
          raised_by?: string | null
          resolution?: string | null
          resolved_at?: string | null
          resolved_by?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_exceptions_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "onboarding_instances"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_instances: {
        Row: {
          activated_at: string | null
          activated_by: string | null
          activation_operation_id: string | null
          activation_reason: string | null
          actual_start_date: string | null
          closed_by: string | null
          closure_snapshot: Json | null
          completed_at: string | null
          created_at: string
          created_by: string | null
          day_one_outcome: string | null
          day_one_recorded_at: string | null
          day_one_recorded_by: string | null
          employee_id: string
          employment_type: Database["public"]["Enums"]["employment_type"] | null
          end_reason: string | null
          ended_at: string | null
          ended_by: string | null
          entity_id: string
          home_location_id: string | null
          id: string
          offer_id: string | null
          position_id: string | null
          proposed_start_date: string | null
          reporting_manager_employee_id: string | null
          row_version: number
          source: string
          source_reason: string | null
          started_at: string
          status: string
          status_changed_at: string
          template_id: string | null
          template_snapshot: Json
          template_version: number | null
          updated_at: string
        }
        Insert: {
          activated_at?: string | null
          activated_by?: string | null
          activation_operation_id?: string | null
          activation_reason?: string | null
          actual_start_date?: string | null
          closed_by?: string | null
          closure_snapshot?: Json | null
          completed_at?: string | null
          created_at?: string
          created_by?: string | null
          day_one_outcome?: string | null
          day_one_recorded_at?: string | null
          day_one_recorded_by?: string | null
          employee_id: string
          employment_type?:
            | Database["public"]["Enums"]["employment_type"]
            | null
          end_reason?: string | null
          ended_at?: string | null
          ended_by?: string | null
          entity_id: string
          home_location_id?: string | null
          id?: string
          offer_id?: string | null
          position_id?: string | null
          proposed_start_date?: string | null
          reporting_manager_employee_id?: string | null
          row_version?: number
          source: string
          source_reason?: string | null
          started_at?: string
          status?: string
          status_changed_at?: string
          template_id?: string | null
          template_snapshot?: Json
          template_version?: number | null
          updated_at?: string
        }
        Update: {
          activated_at?: string | null
          activated_by?: string | null
          activation_operation_id?: string | null
          activation_reason?: string | null
          actual_start_date?: string | null
          closed_by?: string | null
          closure_snapshot?: Json | null
          completed_at?: string | null
          created_at?: string
          created_by?: string | null
          day_one_outcome?: string | null
          day_one_recorded_at?: string | null
          day_one_recorded_by?: string | null
          employee_id?: string
          employment_type?:
            | Database["public"]["Enums"]["employment_type"]
            | null
          end_reason?: string | null
          ended_at?: string | null
          ended_by?: string | null
          entity_id?: string
          home_location_id?: string | null
          id?: string
          offer_id?: string | null
          position_id?: string | null
          proposed_start_date?: string | null
          reporting_manager_employee_id?: string | null
          row_version?: number
          source?: string
          source_reason?: string | null
          started_at?: string
          status?: string
          status_changed_at?: string
          template_id?: string | null
          template_snapshot?: Json
          template_version?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_instances_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_instances_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_instances_home_location_id_fkey"
            columns: ["home_location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_instances_offer_id_fkey"
            columns: ["offer_id"]
            isOneToOne: false
            referencedRelation: "offers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_instances_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_instances_reporting_manager_employee_id_fkey"
            columns: ["reporting_manager_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_instances_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "onboarding_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_invitations: {
        Row: {
          accepted_at: string | null
          access_grant_id: string | null
          employee_id: string
          expires_at: string
          id: string
          instance_id: string
          issued_at: string
          issued_by: string | null
          reissue_of: string | null
          revoke_reason: string | null
          revoked_at: string | null
          revoked_by: string | null
          sent_to_email: string
          status: string
        }
        Insert: {
          accepted_at?: string | null
          access_grant_id?: string | null
          employee_id: string
          expires_at: string
          id?: string
          instance_id: string
          issued_at?: string
          issued_by?: string | null
          reissue_of?: string | null
          revoke_reason?: string | null
          revoked_at?: string | null
          revoked_by?: string | null
          sent_to_email: string
          status?: string
        }
        Update: {
          accepted_at?: string | null
          access_grant_id?: string | null
          employee_id?: string
          expires_at?: string
          id?: string
          instance_id?: string
          issued_at?: string
          issued_by?: string | null
          reissue_of?: string | null
          revoke_reason?: string | null
          revoked_at?: string | null
          revoked_by?: string | null
          sent_to_email?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_invitations_access_grant_id_fkey"
            columns: ["access_grant_id"]
            isOneToOne: false
            referencedRelation: "access_grants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_invitations_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_invitations_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "onboarding_instances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_invitations_reissue_of_fkey"
            columns: ["reissue_of"]
            isOneToOne: false
            referencedRelation: "onboarding_invitations"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_pending_compensation: {
        Row: {
          basic_monthly: number | null
          effective_from: string | null
          hourly_rate: number | null
          instance_id: string
          offer_amount: number | null
          overtime_eligible: boolean
          pay_type: string
          reason: string | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          set_at: string
          set_by: string | null
          status: string
          variance_reason: string | null
        }
        Insert: {
          basic_monthly?: number | null
          effective_from?: string | null
          hourly_rate?: number | null
          instance_id: string
          offer_amount?: number | null
          overtime_eligible?: boolean
          pay_type: string
          reason?: string | null
          review_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          set_at?: string
          set_by?: string | null
          status?: string
          variance_reason?: string | null
        }
        Update: {
          basic_monthly?: number | null
          effective_from?: string | null
          hourly_rate?: number | null
          instance_id?: string
          offer_amount?: number | null
          overtime_eligible?: boolean
          pay_type?: string
          reason?: string | null
          review_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          set_at?: string
          set_by?: string | null
          status?: string
          variance_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_pending_compensation_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: true
            referencedRelation: "onboarding_instances"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_policies: {
        Row: {
          body: string
          created_at: string
          created_by: string | null
          entity_id: string
          id: string
          is_active: boolean
          policy_key: string
          title: string
          version: string
        }
        Insert: {
          body: string
          created_at?: string
          created_by?: string | null
          entity_id: string
          id?: string
          is_active?: boolean
          policy_key: string
          title: string
          version: string
        }
        Update: {
          body?: string
          created_at?: string
          created_by?: string | null
          entity_id?: string
          id?: string
          is_active?: boolean
          policy_key?: string
          title?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_policies_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_reviews: {
        Row: {
          after_state: Json | null
          before_state: Json | null
          created_at: string
          decision: string
          id: string
          instance_id: string
          reason: string | null
          reviewer_id: string
          reviewer_role: string
          section: string
          submission_id: string | null
          task_id: string | null
        }
        Insert: {
          after_state?: Json | null
          before_state?: Json | null
          created_at?: string
          decision: string
          id?: string
          instance_id: string
          reason?: string | null
          reviewer_id: string
          reviewer_role: string
          section: string
          submission_id?: string | null
          task_id?: string | null
        }
        Update: {
          after_state?: Json | null
          before_state?: Json | null
          created_at?: string
          decision?: string
          id?: string
          instance_id?: string
          reason?: string | null
          reviewer_id?: string
          reviewer_role?: string
          section?: string
          submission_id?: string | null
          task_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_reviews_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "onboarding_instances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_reviews_submission_id_fkey"
            columns: ["submission_id"]
            isOneToOne: false
            referencedRelation: "onboarding_section_submissions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_reviews_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "onboarding_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_section_submissions: {
        Row: {
          id: string
          instance_id: string
          section: string
          snapshot: Json
          status: string
          submitted_at: string
          submitted_by: string | null
          version: number
        }
        Insert: {
          id?: string
          instance_id: string
          section: string
          snapshot?: Json
          status?: string
          submitted_at?: string
          submitted_by?: string | null
          version: number
        }
        Update: {
          id?: string
          instance_id?: string
          section?: string
          snapshot?: Json
          status?: string
          submitted_at?: string
          submitted_by?: string | null
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_section_submissions_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "onboarding_instances"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_settings: {
        Row: {
          default_task_sla_days: number
          entity_id: string
          invitation_valid_days: number
          probation_months: number
          probation_review_days_before: number
          require_distinct_activation_approver: boolean
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          default_task_sla_days?: number
          entity_id: string
          invitation_valid_days?: number
          probation_months?: number
          probation_review_days_before?: number
          require_distinct_activation_approver?: boolean
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          default_task_sla_days?: number
          entity_id?: string
          invitation_valid_days?: number
          probation_months?: number
          probation_review_days_before?: number
          require_distinct_activation_approver?: boolean
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_settings_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: true
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_task_dependencies: {
        Row: {
          depends_on_task_id: string
          task_id: string
        }
        Insert: {
          depends_on_task_id: string
          task_id: string
        }
        Update: {
          depends_on_task_id?: string
          task_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_task_dependencies_depends_on_task_id_fkey"
            columns: ["depends_on_task_id"]
            isOneToOne: false
            referencedRelation: "onboarding_tasks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_task_dependencies_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "onboarding_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_tasks: {
        Row: {
          created_at: string
          description: string | null
          doc_type: Database["public"]["Enums"]["document_type"] | null
          due_date: string | null
          evidence: Json | null
          id: string
          instance_id: string
          is_required: boolean
          is_statutory: boolean
          is_waivable: boolean
          item_key: string
          item_label: string
          kind: string
          owner_role: string
          phase: string
          policy_key: string | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          reviewer_role: string | null
          section: string
          sort_order: number
          status: string
          submitted_at: string | null
          submitted_by: string | null
          template_task_id: string | null
          updated_at: string
          waived_at: string | null
          waived_by: string | null
          waived_reason: string | null
        }
        Insert: {
          created_at?: string
          description?: string | null
          doc_type?: Database["public"]["Enums"]["document_type"] | null
          due_date?: string | null
          evidence?: Json | null
          id?: string
          instance_id: string
          is_required?: boolean
          is_statutory?: boolean
          is_waivable?: boolean
          item_key: string
          item_label: string
          kind: string
          owner_role: string
          phase: string
          policy_key?: string | null
          review_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          reviewer_role?: string | null
          section: string
          sort_order?: number
          status?: string
          submitted_at?: string | null
          submitted_by?: string | null
          template_task_id?: string | null
          updated_at?: string
          waived_at?: string | null
          waived_by?: string | null
          waived_reason?: string | null
        }
        Update: {
          created_at?: string
          description?: string | null
          doc_type?: Database["public"]["Enums"]["document_type"] | null
          due_date?: string | null
          evidence?: Json | null
          id?: string
          instance_id?: string
          is_required?: boolean
          is_statutory?: boolean
          is_waivable?: boolean
          item_key?: string
          item_label?: string
          kind?: string
          owner_role?: string
          phase?: string
          policy_key?: string | null
          review_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          reviewer_role?: string | null
          section?: string
          sort_order?: number
          status?: string
          submitted_at?: string | null
          submitted_by?: string | null
          template_task_id?: string | null
          updated_at?: string
          waived_at?: string | null
          waived_by?: string | null
          waived_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_tasks_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "onboarding_instances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_tasks_template_task_id_fkey"
            columns: ["template_task_id"]
            isOneToOne: false
            referencedRelation: "onboarding_template_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_template_tasks: {
        Row: {
          created_at: string
          depends_on: string[]
          description: string | null
          doc_type: Database["public"]["Enums"]["document_type"] | null
          due_offset_days: number | null
          id: string
          is_required: boolean
          is_statutory: boolean
          is_waivable: boolean
          item_key: string
          item_label: string
          kind: string
          owner_role: string
          phase: string
          policy_key: string | null
          reviewer_role: string | null
          section: string
          sort_order: number
          template_id: string
        }
        Insert: {
          created_at?: string
          depends_on?: string[]
          description?: string | null
          doc_type?: Database["public"]["Enums"]["document_type"] | null
          due_offset_days?: number | null
          id?: string
          is_required?: boolean
          is_statutory?: boolean
          is_waivable?: boolean
          item_key: string
          item_label: string
          kind?: string
          owner_role: string
          phase?: string
          policy_key?: string | null
          reviewer_role?: string | null
          section: string
          sort_order?: number
          template_id: string
        }
        Update: {
          created_at?: string
          depends_on?: string[]
          description?: string | null
          doc_type?: Database["public"]["Enums"]["document_type"] | null
          due_offset_days?: number | null
          id?: string
          is_required?: boolean
          is_statutory?: boolean
          is_waivable?: boolean
          item_key?: string
          item_label?: string
          kind?: string
          owner_role?: string
          phase?: string
          policy_key?: string | null
          reviewer_role?: string | null
          section?: string
          sort_order?: number
          template_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_template_tasks_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "onboarding_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_templates: {
        Row: {
          applies_to_employment_types:
            | Database["public"]["Enums"]["employment_type"][]
            | null
          applies_to_position_ids: string[] | null
          created_at: string
          created_by: string | null
          deactivated_at: string | null
          description: string | null
          entity_id: string
          id: string
          is_active: boolean
          name: string
          supersedes_template_id: string | null
          updated_at: string
          version_number: number
        }
        Insert: {
          applies_to_employment_types?:
            | Database["public"]["Enums"]["employment_type"][]
            | null
          applies_to_position_ids?: string[] | null
          created_at?: string
          created_by?: string | null
          deactivated_at?: string | null
          description?: string | null
          entity_id: string
          id?: string
          is_active?: boolean
          name: string
          supersedes_template_id?: string | null
          updated_at?: string
          version_number?: number
        }
        Update: {
          applies_to_employment_types?:
            | Database["public"]["Enums"]["employment_type"][]
            | null
          applies_to_position_ids?: string[] | null
          created_at?: string
          created_by?: string | null
          deactivated_at?: string | null
          description?: string | null
          entity_id?: string
          id?: string
          is_active?: boolean
          name?: string
          supersedes_template_id?: string | null
          updated_at?: string
          version_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_templates_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "onboarding_templates_supersedes_template_id_fkey"
            columns: ["supersedes_template_id"]
            isOneToOne: false
            referencedRelation: "onboarding_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      payable_shift_records: {
        Row: {
          created_at: string
          default_payable_minutes: number
          employee_id: string
          entity_id: string
          final_payable_minutes: number | null
          id: string
          location_id: string
          planned_break_minutes: number
          planned_minutes: number
          shift_id: string
          status: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          default_payable_minutes: number
          employee_id: string
          entity_id: string
          final_payable_minutes?: number | null
          id?: string
          location_id: string
          planned_break_minutes?: number
          planned_minutes: number
          shift_id: string
          status?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          default_payable_minutes?: number
          employee_id?: string
          entity_id?: string
          final_payable_minutes?: number | null
          id?: string
          location_id?: string
          planned_break_minutes?: number
          planned_minutes?: number
          shift_id?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payable_shift_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payable_shift_records_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payable_shift_records_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payable_shift_records_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: true
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_adjustments: {
        Row: {
          allocation: string
          amount: number
          batch_id: string | null
          code: string
          created_at: string
          created_by: string | null
          employee_id: string
          id: string
          kind: string
          period_id: string
          reason: string
          void_reason: string | null
          voided_at: string | null
          voided_by: string | null
        }
        Insert: {
          allocation?: string
          amount: number
          batch_id?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          employee_id: string
          id?: string
          kind: string
          period_id: string
          reason: string
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Update: {
          allocation?: string
          amount?: number
          batch_id?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          employee_id?: string
          id?: string
          kind?: string
          period_id?: string
          reason?: string
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payroll_adjustments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_adjustments_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_export_items: {
        Row: {
          amount: number
          export_id: string
          record_id: string
        }
        Insert: {
          amount: number
          export_id: string
          record_id: string
        }
        Update: {
          amount?: number
          export_id?: string
          record_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_export_items_export_id_fkey"
            columns: ["export_id"]
            isOneToOne: false
            referencedRelation: "payroll_exports"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_export_items_record_id_fkey"
            columns: ["record_id"]
            isOneToOne: false
            referencedRelation: "payroll_records"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_exports: {
        Row: {
          created_at: string
          created_by: string | null
          employee_count: number
          id: string
          invalidated_at: string | null
          invalidated_reason: string | null
          period_id: string
          total_amount: number
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          employee_count: number
          id?: string
          invalidated_at?: string | null
          invalidated_reason?: string | null
          period_id: string
          total_amount: number
        }
        Update: {
          created_at?: string
          created_by?: string | null
          employee_count?: number
          id?: string
          invalidated_at?: string | null
          invalidated_reason?: string | null
          period_id?: string
          total_amount?: number
        }
        Relationships: [
          {
            foreignKeyName: "payroll_exports_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_hours: {
        Row: {
          confirmed_at: string | null
          confirmed_by: string | null
          employee_id: string
          entered_at: string
          entered_by: string | null
          holiday_hours: number
          id: string
          night_overtime_hours: number
          notes: string | null
          overtime_hours: number
          period_id: string
          regular_hours: number
          source: string
          status: string
        }
        Insert: {
          confirmed_at?: string | null
          confirmed_by?: string | null
          employee_id: string
          entered_at?: string
          entered_by?: string | null
          holiday_hours?: number
          id?: string
          night_overtime_hours?: number
          notes?: string | null
          overtime_hours?: number
          period_id: string
          regular_hours?: number
          source?: string
          status?: string
        }
        Update: {
          confirmed_at?: string | null
          confirmed_by?: string | null
          employee_id?: string
          entered_at?: string
          entered_by?: string | null
          holiday_hours?: number
          id?: string
          night_overtime_hours?: number
          notes?: string | null
          overtime_hours?: number
          period_id?: string
          regular_hours?: number
          source?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_hours_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_hours_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_lines: {
        Row: {
          amount: number
          code: string
          explanation: string
          id: string
          kind: string
          label: string
          quantity: number | null
          rate: number | null
          record_id: string
          sort: number
          source_id: string | null
          source_type: string
        }
        Insert: {
          amount?: number
          code: string
          explanation: string
          id?: string
          kind: string
          label: string
          quantity?: number | null
          rate?: number | null
          record_id: string
          sort?: number
          source_id?: string | null
          source_type: string
        }
        Update: {
          amount?: number
          code?: string
          explanation?: string
          id?: string
          kind?: string
          label?: string
          quantity?: number | null
          rate?: number | null
          record_id?: string
          sort?: number
          source_id?: string | null
          source_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_lines_record_id_fkey"
            columns: ["record_id"]
            isOneToOne: false
            referencedRelation: "payroll_records"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_payments: {
        Row: {
          amount: number
          batch_id: string | null
          created_at: string
          created_by: string | null
          failure_reason: string | null
          id: string
          idempotency_key: string
          method: string
          paid_on: string
          record_id: string
          reference: string | null
          status: string
        }
        Insert: {
          amount: number
          batch_id?: string | null
          created_at?: string
          created_by?: string | null
          failure_reason?: string | null
          id?: string
          idempotency_key: string
          method: string
          paid_on: string
          record_id: string
          reference?: string | null
          status: string
        }
        Update: {
          amount?: number
          batch_id?: string | null
          created_at?: string
          created_by?: string | null
          failure_reason?: string | null
          id?: string
          idempotency_key?: string
          method?: string
          paid_on?: string
          record_id?: string
          reference?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_payments_record_id_fkey"
            columns: ["record_id"]
            isOneToOne: false
            referencedRelation: "payroll_records"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_periods: {
        Row: {
          created_at: string
          created_by: string | null
          entity_id: string
          id: string
          kind: string
          label: string | null
          period_end: string
          period_start: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          entity_id: string
          id?: string
          kind?: string
          label?: string | null
          period_end: string
          period_start: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          entity_id?: string
          id?: string
          kind?: string
          label?: string | null
          period_end?: string
          period_start?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_periods_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_permissions: {
        Row: {
          can_single_step_approve: boolean
          entity_id: string
          granted_at: string
          granted_by: string | null
          preset: string
          user_id: string
        }
        Insert: {
          can_single_step_approve?: boolean
          entity_id: string
          granted_at?: string
          granted_by?: string | null
          preset: string
          user_id: string
        }
        Update: {
          can_single_step_approve?: boolean
          entity_id?: string
          granted_at?: string
          granted_by?: string | null
          preset?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_permissions_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_records: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          approved_version: number | null
          attention: Json
          calc_version: number
          calculated_at: string | null
          calculated_by: string | null
          correction_reason: string | null
          created_at: string
          deductions: number
          employee_id: string
          gross: number
          id: string
          net: number
          period_id: string
          published_at: string | null
          published_by: string | null
          record_status: string
          returned_reason: string | null
          submitted_at: string | null
          submitted_by: string | null
          superseded_by_record_id: string | null
          supersedes_record_id: string | null
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          approved_version?: number | null
          attention?: Json
          calc_version?: number
          calculated_at?: string | null
          calculated_by?: string | null
          correction_reason?: string | null
          created_at?: string
          deductions?: number
          employee_id: string
          gross?: number
          id?: string
          net?: number
          period_id: string
          published_at?: string | null
          published_by?: string | null
          record_status?: string
          returned_reason?: string | null
          submitted_at?: string | null
          submitted_by?: string | null
          superseded_by_record_id?: string | null
          supersedes_record_id?: string | null
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          approved_version?: number | null
          attention?: Json
          calc_version?: number
          calculated_at?: string | null
          calculated_by?: string | null
          correction_reason?: string | null
          created_at?: string
          deductions?: number
          employee_id?: string
          gross?: number
          id?: string
          net?: number
          period_id?: string
          published_at?: string | null
          published_by?: string | null
          record_status?: string
          returned_reason?: string | null
          submitted_at?: string | null
          submitted_by?: string | null
          superseded_by_record_id?: string | null
          supersedes_record_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payroll_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_records_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_records_superseded_by_record_id_fkey"
            columns: ["superseded_by_record_id"]
            isOneToOne: false
            referencedRelation: "payroll_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_records_supersedes_record_id_fkey"
            columns: ["supersedes_record_id"]
            isOneToOne: false
            referencedRelation: "payroll_records"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_runs: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          created_at: string | null
          created_by: string | null
          entity_id: string
          id: string
          overtime_holiday_pay_confirmed: boolean
          period_end: string
          period_start: string
          revises_payroll_run_id: string | null
          status: string
          tip_distribution_rule: string
          tips_distribution_confirmed: boolean
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string | null
          created_by?: string | null
          entity_id: string
          id?: string
          overtime_holiday_pay_confirmed?: boolean
          period_end: string
          period_start: string
          revises_payroll_run_id?: string | null
          status?: string
          tip_distribution_rule?: string
          tips_distribution_confirmed?: boolean
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string | null
          created_by?: string | null
          entity_id?: string
          id?: string
          overtime_holiday_pay_confirmed?: boolean
          period_end?: string
          period_start?: string
          revises_payroll_run_id?: string | null
          status?: string
          tip_distribution_rule?: string
          tips_distribution_confirmed?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "payroll_runs_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_runs_revises_payroll_run_id_fkey"
            columns: ["revises_payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_run_totals"
            referencedColumns: ["payroll_run_id"]
          },
          {
            foreignKeyName: "payroll_runs_revises_payroll_run_id_fkey"
            columns: ["revises_payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_settings: {
        Row: {
          approval_mode: string
          confirmed: boolean
          created_at: string
          created_by: string | null
          day_rate_basis: string
          default_payment_method: string
          effective_from: string
          entity_id: string
          holiday_multiplier: number
          id: string
          max_deduction_pct: number
          night_overtime_multiplier: number
          overtime_hour_divisor: number
          overtime_multiplier: number
          pay_day: number
          payslip_note: string | null
          unpaid_leave_basis: string
        }
        Insert: {
          approval_mode?: string
          confirmed?: boolean
          created_at?: string
          created_by?: string | null
          day_rate_basis?: string
          default_payment_method?: string
          effective_from: string
          entity_id: string
          holiday_multiplier?: number
          id?: string
          max_deduction_pct?: number
          night_overtime_multiplier?: number
          overtime_hour_divisor?: number
          overtime_multiplier?: number
          pay_day?: number
          payslip_note?: string | null
          unpaid_leave_basis?: string
        }
        Update: {
          approval_mode?: string
          confirmed?: boolean
          created_at?: string
          created_by?: string | null
          day_rate_basis?: string
          default_payment_method?: string
          effective_from?: string
          entity_id?: string
          holiday_multiplier?: number
          id?: string
          max_deduction_pct?: number
          night_overtime_multiplier?: number
          overtime_hour_divisor?: number
          overtime_multiplier?: number
          pay_day?: number
          payslip_note?: string | null
          unpaid_leave_basis?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_settings_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      payslip_deductions: {
        Row: {
          amount: number
          created_at: string | null
          deduction_type: string
          employee_id: string
          id: string
          notes: string | null
          payroll_run_id: string
        }
        Insert: {
          amount: number
          created_at?: string | null
          deduction_type: string
          employee_id: string
          id?: string
          notes?: string | null
          payroll_run_id: string
        }
        Update: {
          amount?: number
          created_at?: string | null
          deduction_type?: string
          employee_id?: string
          id?: string
          notes?: string | null
          payroll_run_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "payslip_deductions_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payslip_deductions_payroll_run_id_fkey"
            columns: ["payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_run_totals"
            referencedColumns: ["payroll_run_id"]
          },
          {
            foreignKeyName: "payslip_deductions_payroll_run_id_fkey"
            columns: ["payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      payslips: {
        Row: {
          base_pay: number
          employee_id: string
          generated_at: string | null
          holiday_pay: number
          id: string
          net_pay: number
          overtime_pay: number
          payroll_run_id: string
          tips_share: number
          total_deductions: number
        }
        Insert: {
          base_pay?: number
          employee_id: string
          generated_at?: string | null
          holiday_pay?: number
          id?: string
          net_pay?: number
          overtime_pay?: number
          payroll_run_id: string
          tips_share?: number
          total_deductions?: number
        }
        Update: {
          base_pay?: number
          employee_id?: string
          generated_at?: string | null
          holiday_pay?: number
          id?: string
          net_pay?: number
          overtime_pay?: number
          payroll_run_id?: string
          tips_share?: number
          total_deductions?: number
        }
        Relationships: [
          {
            foreignKeyName: "payslips_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payslips_payroll_run_id_fkey"
            columns: ["payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_run_totals"
            referencedColumns: ["payroll_run_id"]
          },
          {
            foreignKeyName: "payslips_payroll_run_id_fkey"
            columns: ["payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      positions: {
        Row: {
          created_at: string | null
          department: string | null
          description: string | null
          entity_id: string
          id: string
          title: string
        }
        Insert: {
          created_at?: string | null
          department?: string | null
          description?: string | null
          entity_id: string
          id?: string
          title: string
        }
        Update: {
          created_at?: string | null
          department?: string | null
          description?: string | null
          entity_id?: string
          id?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "positions_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          created_at: string | null
          deactivated_at: string | null
          deactivated_by: string | null
          deactivation_reason: string | null
          entity_id: string | null
          full_name: string | null
          id: string
          is_active: boolean
          location_id: string | null
          role: Database["public"]["Enums"]["user_role"]
        }
        Insert: {
          created_at?: string | null
          deactivated_at?: string | null
          deactivated_by?: string | null
          deactivation_reason?: string | null
          entity_id?: string | null
          full_name?: string | null
          id: string
          is_active?: boolean
          location_id?: string | null
          role?: Database["public"]["Enums"]["user_role"]
        }
        Update: {
          created_at?: string | null
          deactivated_at?: string | null
          deactivated_by?: string | null
          deactivation_reason?: string | null
          entity_id?: string | null
          full_name?: string | null
          id?: string
          is_active?: boolean
          location_id?: string | null
          role?: Database["public"]["Enums"]["user_role"]
        }
        Relationships: [
          {
            foreignKeyName: "profiles_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profiles_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
        ]
      }
      salary_advances: {
        Row: {
          amount: number
          cancelled_reason: string | null
          created_at: string
          created_by: string | null
          disbursed_on: string
          disbursement_method: string
          employee_id: string
          entity_id: string
          id: string
          instalment_amount: number
          instalments: number
          reason: string
          repayment_start: string
          status: string
        }
        Insert: {
          amount: number
          cancelled_reason?: string | null
          created_at?: string
          created_by?: string | null
          disbursed_on: string
          disbursement_method?: string
          employee_id: string
          entity_id: string
          id?: string
          instalment_amount: number
          instalments: number
          reason: string
          repayment_start: string
          status?: string
        }
        Update: {
          amount?: number
          cancelled_reason?: string | null
          created_at?: string
          created_by?: string | null
          disbursed_on?: string
          disbursement_method?: string
          employee_id?: string
          entity_id?: string
          id?: string
          instalment_amount?: number
          instalments?: number
          reason?: string
          repayment_start?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "salary_advances_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "salary_advances_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      schedule_templates: {
        Row: {
          break_minutes: number
          created_at: string
          created_by: string | null
          day_of_week: number
          effective_end_date: string | null
          effective_start_date: string
          employee_id: string
          end_time: string
          entity_id: string
          id: string
          is_active: boolean
          location_id: string
          position_id: string | null
          start_time: string
          supersedes_template_id: string | null
          updated_at: string
          version_number: number
        }
        Insert: {
          break_minutes?: number
          created_at?: string
          created_by?: string | null
          day_of_week: number
          effective_end_date?: string | null
          effective_start_date: string
          employee_id: string
          end_time: string
          entity_id: string
          id?: string
          is_active?: boolean
          location_id: string
          position_id?: string | null
          start_time: string
          supersedes_template_id?: string | null
          updated_at?: string
          version_number?: number
        }
        Update: {
          break_minutes?: number
          created_at?: string
          created_by?: string | null
          day_of_week?: number
          effective_end_date?: string | null
          effective_start_date?: string
          employee_id?: string
          end_time?: string
          entity_id?: string
          id?: string
          is_active?: boolean
          location_id?: string
          position_id?: string | null
          start_time?: string
          supersedes_template_id?: string | null
          updated_at?: string
          version_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "schedule_templates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_templates_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_templates_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_templates_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_templates_supersedes_template_id_fkey"
            columns: ["supersedes_template_id"]
            isOneToOne: false
            referencedRelation: "schedule_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      shift_adjustments: {
        Row: {
          change_type: string
          changed_at: string
          changed_by: string | null
          employee_id: string | null
          entity_id: string
          id: string
          location_id: string | null
          new_values: Json | null
          old_values: Json
          previous_employee_id: string | null
          reason: string | null
          shift_id: string
        }
        Insert: {
          change_type: string
          changed_at?: string
          changed_by?: string | null
          employee_id?: string | null
          entity_id: string
          id?: string
          location_id?: string | null
          new_values?: Json | null
          old_values: Json
          previous_employee_id?: string | null
          reason?: string | null
          shift_id: string
        }
        Update: {
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          employee_id?: string | null
          entity_id?: string
          id?: string
          location_id?: string | null
          new_values?: Json | null
          old_values?: Json
          previous_employee_id?: string | null
          reason?: string | null
          shift_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shift_adjustments_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
      shift_swap_requests: {
        Row: {
          claimed_by: string | null
          created_at: string | null
          id: string
          notes: string | null
          requested_by: string
          resolved_at: string | null
          resolved_by: string | null
          shift_id: string
          status: string
        }
        Insert: {
          claimed_by?: string | null
          created_at?: string | null
          id?: string
          notes?: string | null
          requested_by: string
          resolved_at?: string | null
          resolved_by?: string | null
          shift_id: string
          status?: string
        }
        Update: {
          claimed_by?: string | null
          created_at?: string | null
          id?: string
          notes?: string | null
          requested_by?: string
          resolved_at?: string | null
          resolved_by?: string | null
          shift_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "shift_swap_requests_claimed_by_fkey"
            columns: ["claimed_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_swap_requests_requested_by_fkey"
            columns: ["requested_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_swap_requests_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
        ]
      }
      shifts: {
        Row: {
          break_minutes: number
          created_at: string | null
          created_by: string | null
          employee_id: string | null
          end_time: string
          entity_id: string
          generated_from_template_id: string | null
          id: string
          is_published: boolean
          location_id: string
          notes: string | null
          position_id: string | null
          shift_date: string
          start_time: string
          status: string
        }
        Insert: {
          break_minutes?: number
          created_at?: string | null
          created_by?: string | null
          employee_id?: string | null
          end_time: string
          entity_id: string
          generated_from_template_id?: string | null
          id?: string
          is_published?: boolean
          location_id: string
          notes?: string | null
          position_id?: string | null
          shift_date: string
          start_time: string
          status?: string
        }
        Update: {
          break_minutes?: number
          created_at?: string | null
          created_by?: string | null
          employee_id?: string | null
          end_time?: string
          entity_id?: string
          generated_from_template_id?: string | null
          id?: string
          is_published?: boolean
          location_id?: string
          notes?: string | null
          position_id?: string | null
          shift_date?: string
          start_time?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "shifts_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_generated_from_template_id_fkey"
            columns: ["generated_from_template_id"]
            isOneToOne: false
            referencedRelation: "schedule_templates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
        ]
      }
      timesheet_entries: {
        Row: {
          employee_id: string
          holiday_hours: number
          id: string
          notes: string | null
          overtime_hours: number
          payroll_run_id: string
          regular_hours: number
          source_locked: boolean
        }
        Insert: {
          employee_id: string
          holiday_hours?: number
          id?: string
          notes?: string | null
          overtime_hours?: number
          payroll_run_id: string
          regular_hours?: number
          source_locked?: boolean
        }
        Update: {
          employee_id?: string
          holiday_hours?: number
          id?: string
          notes?: string | null
          overtime_hours?: number
          payroll_run_id?: string
          regular_hours?: number
          source_locked?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "timesheet_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "timesheet_entries_payroll_run_id_fkey"
            columns: ["payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_run_totals"
            referencedColumns: ["payroll_run_id"]
          },
          {
            foreignKeyName: "timesheet_entries_payroll_run_id_fkey"
            columns: ["payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      timesheet_entry_sources: {
        Row: {
          contributed_minutes: number
          created_at: string
          id: string
          payable_shift_record_id: string
          payroll_run_id: string
          timesheet_entry_id: string
        }
        Insert: {
          contributed_minutes: number
          created_at?: string
          id?: string
          payable_shift_record_id: string
          payroll_run_id: string
          timesheet_entry_id: string
        }
        Update: {
          contributed_minutes?: number
          created_at?: string
          id?: string
          payable_shift_record_id?: string
          payroll_run_id?: string
          timesheet_entry_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "timesheet_entry_sources_payable_shift_record_id_fkey"
            columns: ["payable_shift_record_id"]
            isOneToOne: false
            referencedRelation: "payable_shift_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "timesheet_entry_sources_payroll_run_id_fkey"
            columns: ["payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_run_totals"
            referencedColumns: ["payroll_run_id"]
          },
          {
            foreignKeyName: "timesheet_entry_sources_payroll_run_id_fkey"
            columns: ["payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "timesheet_entry_sources_timesheet_entry_id_fkey"
            columns: ["timesheet_entry_id"]
            isOneToOne: false
            referencedRelation: "timesheet_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      tip_allocations: {
        Row: {
          amount: number
          employee_id: string
          hours: number | null
          id: string
          points: number | null
          pool_id: string
          weight: number
        }
        Insert: {
          amount: number
          employee_id: string
          hours?: number | null
          id?: string
          points?: number | null
          pool_id: string
          weight: number
        }
        Update: {
          amount?: number
          employee_id?: string
          hours?: number | null
          id?: string
          points?: number | null
          pool_id?: string
          weight?: number
        }
        Relationships: [
          {
            foreignKeyName: "tip_allocations_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tip_allocations_pool_id_fkey"
            columns: ["pool_id"]
            isOneToOne: false
            referencedRelation: "tip_pools"
            referencedColumns: ["id"]
          },
        ]
      }
      tip_pools: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          location_id: string
          method: string
          notes: string | null
          period_id: string
          pool_end: string
          pool_start: string
          settlement: string
          total_amount: number
          voided_at: string | null
          voided_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          location_id: string
          method: string
          notes?: string | null
          period_id: string
          pool_end: string
          pool_start: string
          settlement: string
          total_amount: number
          voided_at?: string | null
          voided_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          location_id?: string
          method?: string
          notes?: string | null
          period_id?: string
          pool_end?: string
          pool_start?: string
          settlement?: string
          total_amount?: number
          voided_at?: string | null
          voided_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "tip_pools_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tip_pools_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      tip_role_points: {
        Row: {
          points: number
          position_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          points: number
          position_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          points?: number
          position_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "tip_role_points_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: true
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
        ]
      }
      tips_pools: {
        Row: {
          id: string
          location_id: string
          notes: string | null
          payroll_run_id: string
          total_amount: number
          updated_at: string | null
        }
        Insert: {
          id?: string
          location_id: string
          notes?: string | null
          payroll_run_id: string
          total_amount?: number
          updated_at?: string | null
        }
        Update: {
          id?: string
          location_id?: string
          notes?: string | null
          payroll_run_id?: string
          total_amount?: number
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "tips_pools_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tips_pools_payroll_run_id_fkey"
            columns: ["payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_run_totals"
            referencedColumns: ["payroll_run_id"]
          },
          {
            foreignKeyName: "tips_pools_payroll_run_id_fkey"
            columns: ["payroll_run_id"]
            isOneToOne: false
            referencedRelation: "payroll_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_rules: {
        Row: {
          action_message_template: string
          action_target_role: Database["public"]["Enums"]["user_role"] | null
          action_type: string
          activated_at: string | null
          condition_field: string | null
          condition_operator: string | null
          condition_value: string | null
          created_at: string
          created_by: string | null
          deactivated_at: string | null
          entity_id: string
          id: string
          is_active: boolean
          is_starter: boolean
          module: string
          name: string
          supersedes_rule_id: string | null
          trigger_event: string
          updated_at: string
          version_number: number
        }
        Insert: {
          action_message_template: string
          action_target_role?: Database["public"]["Enums"]["user_role"] | null
          action_type: string
          activated_at?: string | null
          condition_field?: string | null
          condition_operator?: string | null
          condition_value?: string | null
          created_at?: string
          created_by?: string | null
          deactivated_at?: string | null
          entity_id: string
          id?: string
          is_active?: boolean
          is_starter?: boolean
          module: string
          name: string
          supersedes_rule_id?: string | null
          trigger_event: string
          updated_at?: string
          version_number?: number
        }
        Update: {
          action_message_template?: string
          action_target_role?: Database["public"]["Enums"]["user_role"] | null
          action_type?: string
          activated_at?: string | null
          condition_field?: string | null
          condition_operator?: string | null
          condition_value?: string | null
          created_at?: string
          created_by?: string | null
          deactivated_at?: string | null
          entity_id?: string
          id?: string
          is_active?: boolean
          is_starter?: boolean
          module?: string
          name?: string
          supersedes_rule_id?: string | null
          trigger_event?: string
          updated_at?: string
          version_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "workflow_rules_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_rules_supersedes_rule_id_fkey"
            columns: ["supersedes_rule_id"]
            isOneToOne: false
            referencedRelation: "workflow_rules"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_runs: {
        Row: {
          details: Json | null
          entity_id: string
          event_type: string
          id: string
          ran_at: string
          result: string
          rule_id: string
          source_record_id: string
          source_table: string
        }
        Insert: {
          details?: Json | null
          entity_id: string
          event_type: string
          id?: string
          ran_at?: string
          result: string
          rule_id: string
          source_record_id: string
          source_table: string
        }
        Update: {
          details?: Json | null
          entity_id?: string
          event_type?: string
          id?: string
          ran_at?: string
          result?: string
          rule_id?: string
          source_record_id?: string
          source_table?: string
        }
        Relationships: [
          {
            foreignKeyName: "workflow_runs_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_runs_rule_id_fkey"
            columns: ["rule_id"]
            isOneToOne: false
            referencedRelation: "workflow_rules"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      compliance_alerts: {
        Row: {
          days_remaining: number | null
          doc_type: string | null
          employee_id: string | null
          entity_id: string | null
          expiry_date: string | null
          full_name: string | null
          home_location_id: string | null
          urgency: string | null
        }
        Relationships: []
      }
      payroll_run_totals: {
        Row: {
          employee_count: number | null
          entity_id: string | null
          payroll_run_id: string | null
          period_end: string | null
          period_start: string | null
          status: string | null
          total_base_pay: number | null
          total_deductions: number | null
          total_holiday_pay: number | null
          total_net_pay: number | null
          total_overtime_pay: number | null
          total_tips: number | null
        }
        Relationships: [
          {
            foreignKeyName: "payroll_runs_entity_id_fkey"
            columns: ["entity_id"]
            isOneToOne: false
            referencedRelation: "entities"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      _apply_access_grant: {
        Args: { p_grant_id: string; p_user_id: string }
        Returns: undefined
      }
      _auto_schedule: {
        Args: {
          p_end: string
          p_entity_id: string
          p_location_ids: string[]
          p_start: string
        }
        Returns: Json
      }
      _auto_schedule_check: {
        Args: {
          p_entity_id: string
          p_period_end: string
          p_period_start: string
        }
        Returns: undefined
      }
      _canonical_emirate: { Args: { p_emirate: string }; Returns: string }
      _imm_audit: {
        Args: {
          p_action: string
          p_case: Database["public"]["Tables"]["employee_immigration_cases"]["Row"]
          p_new: Json
          p_old: Json
          p_record: string
        }
        Returns: undefined
      }
      _imm_reminders: { Args: { p_today: string }; Returns: number }
      _imm_require: { Args: { p_entity_id: string }; Returns: undefined }
      _imm_step_catalog: {
        Args: never
        Returns: {
          due_days: number
          is_blocking: boolean
          label: string
          sort_order: number
          step_key: string
          tracks: string[]
        }[]
      }
      _maintenance_bypass: { Args: never; Returns: boolean }
      _off_audit: {
        Args: {
          p_action: string
          p_case: Database["public"]["Tables"]["offboarding_cases"]["Row"]
          p_new: Json
          p_old: Json
          p_record: string
        }
        Returns: undefined
      }
      _off_can: { Args: { p_cap: string; p_case_id: string }; Returns: boolean }
      _off_generate_tasks: { Args: { p_case_id: string }; Returns: number }
      _off_min_notice_days: {
        Args: {
          p_in_probation: boolean
          p_initiated_by: string
          p_leaving_uae: boolean
          p_type: string
        }
        Returns: number
      }
      _off_reminders: { Args: { p_today: string }; Returns: number }
      _off_sync_settlement: { Args: { p_case_id: string }; Returns: undefined }
      _onb_advance_post_start: {
        Args: { p_instance_id: string }
        Returns: undefined
      }
      _onb_audit: {
        Args: {
          p_action: string
          p_instance_id: string
          p_new: Json
          p_old: Json
          p_record_id: string
          p_table: string
        }
        Returns: undefined
      }
      _onb_can: {
        Args: { p_cap: string; p_instance_id: string }
        Returns: boolean
      }
      _onb_can_own: {
        Args: { p_instance_id: string; p_owner_role: string }
        Returns: boolean
      }
      _onb_can_review: {
        Args: { p_instance_id: string; p_reviewer_role: string }
        Returns: boolean
      }
      _onb_create_instance: {
        Args: {
          p_employee_id: string
          p_manager: string
          p_offer_id: string
          p_reason: string
          p_source: string
          p_start_date: string
        }
        Returns: string
      }
      _onb_duplicate_count: {
        Args: {
          p_email: string
          p_entity_id: string
          p_exclude: string
          p_phone: string
        }
        Returns: number
      }
      _onb_end: {
        Args: { p_instance_id: string; p_reason: string; p_status: string }
        Returns: Json
      }
      _onb_extension_checks: {
        Args: { p_audience: string; p_instance_id: string }
        Returns: Json
      }
      _onb_extension_reminders: { Args: { p_today: string }; Returns: number }
      _onb_generate_tasks: {
        Args: { p_instance_id: string; p_phase: string }
        Returns: number
      }
      _onb_insert_template_tasks: {
        Args: { p_tasks: Json; p_template_id: string }
        Returns: number
      }
      _onb_is_self: { Args: { p_instance_id: string }; Returns: boolean }
      _onb_my_open_instance: {
        Args: never
        Returns: {
          activated_at: string | null
          activated_by: string | null
          activation_operation_id: string | null
          activation_reason: string | null
          actual_start_date: string | null
          closed_by: string | null
          closure_snapshot: Json | null
          completed_at: string | null
          created_at: string
          created_by: string | null
          day_one_outcome: string | null
          day_one_recorded_at: string | null
          day_one_recorded_by: string | null
          employee_id: string
          employment_type: Database["public"]["Enums"]["employment_type"] | null
          end_reason: string | null
          ended_at: string | null
          ended_by: string | null
          entity_id: string
          home_location_id: string | null
          id: string
          offer_id: string | null
          position_id: string | null
          proposed_start_date: string | null
          reporting_manager_employee_id: string | null
          row_version: number
          source: string
          source_reason: string | null
          started_at: string
          status: string
          status_changed_at: string
          template_id: string | null
          template_snapshot: Json
          template_version: number | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "onboarding_instances"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _onb_next_employee_number: {
        Args: { p_entity_id: string }
        Returns: string
      }
      _onb_op: { Args: never; Returns: string }
      _onb_pick_template: {
        Args: {
          p_entity_id: string
          p_position_id: string
          p_type: Database["public"]["Enums"]["employment_type"]
        }
        Returns: string
      }
      _onb_probation_scope: {
        Args: { p_cap: string; p_period_id: string }
        Returns: {
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_effective_date: string | null
          decision_reason: string | null
          employee_id: string
          end_date: string
          id: string
          onboarding_instance_id: string | null
          previous_period_id: string | null
          review_due_date: string
          start_date: string
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "employee_probation_periods"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _onb_readiness: {
        Args: { p_audience?: string; p_instance_id: string }
        Returns: Json
      }
      _onb_recompute: { Args: { p_instance_id: string }; Returns: Json }
      _onb_require: {
        Args: { p_cap: string; p_instance_id: string }
        Returns: undefined
      }
      _onb_set_status: {
        Args: { p_instance_id: string; p_reason?: string; p_to: string }
        Returns: undefined
      }
      _onb_settings: {
        Args: { p_entity_id: string }
        Returns: {
          default_task_sla_days: number
          entity_id: string
          invitation_valid_days: number
          probation_months: number
          probation_review_days_before: number
          require_distinct_activation_approver: boolean
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "onboarding_settings"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _onb_sync_derived: { Args: { p_instance_id: string }; Returns: undefined }
      _onb_touch: { Args: { p_instance_id: string }; Returns: undefined }
      _onb_transition_allowed: {
        Args: { p_from: string; p_to: string }
        Returns: boolean
      }
      _onb_validate_tasks: { Args: { p_tasks: Json }; Returns: undefined }
      _payroll_audit: {
        Args: {
          p_action: string
          p_employee_id?: string
          p_entity_id: string
          p_new: Json
          p_old: Json
          p_record_id: string
          p_table: string
        }
        Returns: undefined
      }
      _payroll_calculate: { Args: { p_record_id: string }; Returns: undefined }
      _payroll_can_edit_pay: {
        Args: { p_employee_id: string }
        Returns: string
      }
      _payroll_comp_on: {
        Args: { p_employee_id: string; p_on: string }
        Returns: {
          basic_monthly: number | null
          created_at: string
          created_by: string | null
          effective_from: string
          employee_id: string
          hourly_rate: number | null
          id: string
          overtime_eligible: boolean
          pay_type: string
          reason: string | null
        }
        SetofOptions: {
          from: "*"
          to: "compensation_versions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _payroll_fixed_monthly_on: {
        Args: {
          p_employee_id: string
          p_include_allowances: boolean
          p_on: string
        }
        Returns: number
      }
      _payroll_fmt: { Args: { p: number }; Returns: string }
      _payroll_fmt_date: { Args: { p: string }; Returns: string }
      _payroll_frozen_reason: {
        Args: { p_employee_id: string; p_period_id: string }
        Returns: string
      }
      _payroll_ineligible_reason: {
        Args: { p_employee_id: string; p_period_id: string }
        Returns: string
      }
      _payroll_money: {
        Args: { p_record_id: string }
        Returns: {
          failed_attempts: number
          outstanding: number
          paid: number
          payment_status: string
        }[]
      }
      _payroll_refresh: {
        Args: { p_employee_id: string; p_period_id: string }
        Returns: undefined
      }
      _payroll_refresh_employee: {
        Args: { p_employee_id: string; p_from: string }
        Returns: undefined
      }
      _payroll_require: {
        Args: { p_cap: string; p_entity_id: string }
        Returns: undefined
      }
      _payroll_row: { Args: { p_record_id: string }; Returns: Json }
      _payroll_run_version: {
        Args: { p_payroll_run_id: string }
        Returns: number
      }
      _payroll_settings: {
        Args: { p_entity_id: string; p_on: string }
        Returns: {
          approval_mode: string
          confirmed: boolean
          created_at: string
          created_by: string | null
          day_rate_basis: string
          default_payment_method: string
          effective_from: string
          entity_id: string
          holiday_multiplier: number
          id: string
          max_deduction_pct: number
          night_overtime_multiplier: number
          overtime_hour_divisor: number
          overtime_multiplier: number
          pay_day: number
          payslip_note: string | null
          unpaid_leave_basis: string
        }
        SetofOptions: {
          from: "*"
          to: "payroll_settings"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _payroll_tip_split: {
        Args: {
          p_amount: number
          p_employee_ids: string[]
          p_end: string
          p_location_id: string
          p_method: string
          p_period_id: string
          p_settlement: string
          p_start: string
        }
        Returns: Json
      }
      _require_entity_admin: {
        Args: { p_entity_id: string }
        Returns: undefined
      }
      _shift_planned_bounds: {
        Args: { p_end: string; p_shift_date: string; p_start: string }
        Returns: Record<string, unknown>
      }
      _workflow_scope_entity: { Args: { p_entity_id: string }; Returns: string }
      accept_employment_contract: {
        Args: { p_onboarding_instance_id: string }
        Returns: Json
      }
      acknowledge_onboarding_policy: {
        Args: { p_policy_id: string }
        Returns: Json
      }
      activate_workflow_rule: {
        Args: { p_rule_id: string }
        Returns: undefined
      }
      add_employees_to_payroll_run: {
        Args: { p_payroll_run_id: string }
        Returns: number
      }
      adjust_leave_balance: {
        Args: {
          p_employee_id: string
          p_leave_type_id: string
          p_new_balance: number
          p_reason: string
        }
        Returns: undefined
      }
      adjust_published_shift: {
        Args: {
          p_break_minutes?: number
          p_employee_id?: string
          p_end_time?: string
          p_location_id?: string
          p_reason: string
          p_shift_date?: string
          p_shift_id: string
          p_start_time?: string
        }
        Returns: undefined
      }
      admin_grant_access: {
        Args: {
          p_email: string
          p_employee_id: string
          p_entity_id: string
          p_location_id: string
          p_role: Database["public"]["Enums"]["user_role"]
        }
        Returns: string
      }
      admin_list_user_access: {
        Args: { p_entity_id: string }
        Returns: {
          email: string
          employee_id: string
          entity_id: string
          full_name: string
          grant_id: string
          is_active: boolean
          is_pending: boolean
          last_sign_in_at: string
          location_id: string
          role: Database["public"]["Enums"]["user_role"]
          user_id: string
        }[]
      }
      admin_revoke_access: {
        Args: { p_grant_id: string; p_reason: string; p_user_id: string }
        Returns: undefined
      }
      admin_upsert_entity: {
        Args: {
          p_code: string
          p_default_currency: string
          p_emirate: string
          p_id: string
          p_is_active: boolean
          p_name: string
          p_payroll_day: number
          p_trade_license_no: string
        }
        Returns: string
      }
      admin_upsert_location: {
        Args: {
          p_address: string
          p_code: string
          p_entity_id: string
          p_id: string
          p_is_active: boolean
          p_name: string
        }
        Returns: string
      }
      apply_attendance_adjustment: {
        Args: { p_adjustment_id: string }
        Returns: Json
      }
      apply_auto_schedule: {
        Args: {
          p_entity_id: string
          p_location_ids?: string[]
          p_period_end: string
          p_period_start: string
        }
        Returns: Json
      }
      approve_and_activate_employee: {
        Args: {
          p_expected_version: number
          p_instance_id: string
          p_reason?: string
        }
        Returns: Json
      }
      approve_data_retention_policy: {
        Args: { p_policy_id: string }
        Returns: undefined
      }
      approve_document: { Args: { p_document_id: string }; Returns: undefined }
      approve_leave_accrual_policy: {
        Args: { p_policy_id: string }
        Returns: undefined
      }
      approve_leave_request: {
        Args: {
          p_action: string
          p_override?: boolean
          p_override_reason?: string
          p_request_id: string
        }
        Returns: undefined
      }
      approve_shift_swap: {
        Args: { p_action: string; p_swap_id: string }
        Returns: undefined
      }
      archive_document: { Args: { p_document_id: string }; Returns: undefined }
      bulk_import_employees: {
        Args: { p_entity_id: string; p_rows: Json }
        Returns: {
          employee_id: string
          errors: string[]
          row_index: number
          success: boolean
        }[]
      }
      calculate_onboarding_readiness: {
        Args: { p_instance_id: string }
        Returns: Json
      }
      can_review_document: {
        Args: {
          p_doc_type: Database["public"]["Enums"]["document_type"]
          p_reviewed_by: string
          p_submitted_by: string
        }
        Returns: boolean
      }
      cancel_interview: {
        Args: { p_interview_id: string; p_reason: string }
        Returns: undefined
      }
      cancel_leave_request: {
        Args: { p_reason?: string; p_request_id: string }
        Returns: Json
      }
      cancel_offboarding: {
        Args: { p_case_id: string; p_reason: string }
        Returns: Json
      }
      cancel_onboarding: {
        Args: { p_instance_id: string; p_reason: string }
        Returns: Json
      }
      cancel_published_shift: {
        Args: { p_reason: string; p_shift_id: string }
        Returns: undefined
      }
      cancel_shift_swap_request: {
        Args: { p_swap_id: string }
        Returns: undefined
      }
      change_immigration_track: {
        Args: { p_case_id: string; p_reason: string; p_track: string }
        Returns: Json
      }
      check_shift_work_pattern: {
        Args: {
          p_employee_id: string
          p_exclude_shift_id?: string
          p_shift_date: string
        }
        Returns: Json
      }
      claim_open_shift: { Args: { p_shift_id: string }; Returns: undefined }
      claim_shift_swap: { Args: { p_swap_id: string }; Returns: undefined }
      cleanup_incomplete_document_uploads: {
        Args: { p_older_than_hours?: number }
        Returns: number
      }
      clear_employee_work_pattern: {
        Args: { p_employee_id: string }
        Returns: undefined
      }
      clock_in: { Args: never; Returns: Json }
      clock_out: { Args: never; Returns: Json }
      close_immigration_case: {
        Args: { p_case_id: string; p_reason?: string; p_status: string }
        Returns: Json
      }
      close_interview_round: {
        Args: { p_application_id: string; p_reason: string; p_stage_id: string }
        Returns: Json
      }
      close_onboarding: {
        Args: { p_instance_id: string; p_notes?: string }
        Returns: Json
      }
      complete_offboarding: {
        Args: { p_case_id: string; p_notes?: string }
        Returns: Json
      }
      complete_offboarding_task: {
        Args: { p_notes?: string; p_status: string; p_task_id: string }
        Returns: Json
      }
      complete_onboarding_task: {
        Args: { p_evidence?: Json; p_task_id: string }
        Returns: Json
      }
      configure_leave_accrual_policy: {
        Args: {
          p_carry_forward_cap_days: number
          p_days_per_period: number
          p_frequency: string
          p_leave_type_id: string
          p_max_balance_days: number
          p_policy_start_date: string
          p_probation_days: number
          p_rounding: string
        }
        Returns: string
      }
      confirm_document_upload: {
        Args: { p_document_id: string }
        Returns: Json
      }
      convert_offer_to_employee: {
        Args: { p_offer_id: string }
        Returns: string
      }
      correct_attendance_record: {
        Args: {
          p_new_clock_in_at: string
          p_new_clock_out_at: string
          p_reason: string
          p_record_id: string
        }
        Returns: undefined
      }
      create_document_upload: {
        Args: {
          p_doc_type: Database["public"]["Enums"]["document_type"]
          p_employee_id: string
          p_expiry_date?: string
          p_notes?: string
          p_storage_path: string
        }
        Returns: Json
      }
      create_notification: {
        Args: {
          p_dedupe_key?: string
          p_employee_id: string
          p_entity_id: string
          p_message: string
          p_notification_type: string
          p_priority?: string
          p_recipient_user_id: string
          p_target_id?: string
          p_target_type?: string
          p_title: string
        }
        Returns: string
      }
      create_onboarding_template: {
        Args: {
          p_description: string
          p_employment_types?: Database["public"]["Enums"]["employment_type"][]
          p_entity_id: string
          p_name: string
          p_position_ids?: string[]
          p_tasks: Json
        }
        Returns: string
      }
      create_payroll_revision: {
        Args: { p_source_run_id: string }
        Returns: string
      }
      create_schedule_template: {
        Args: {
          p_break_minutes: number
          p_day_of_week: number
          p_effective_end_date: string
          p_effective_start_date: string
          p_employee_id: string
          p_end_time: string
          p_location_id: string
          p_position_id: string
          p_start_time: string
        }
        Returns: string
      }
      create_workflow_rule: {
        Args: {
          p_action_message_template: string
          p_action_target_role: Database["public"]["Enums"]["user_role"]
          p_action_type: string
          p_condition_field: string
          p_condition_operator: string
          p_condition_value: string
          p_entity_id?: string
          p_module: string
          p_name: string
          p_trigger_event: string
        }
        Returns: string
      }
      deactivate_onboarding_template: {
        Args: { p_template_id: string }
        Returns: undefined
      }
      deactivate_schedule_template: {
        Args: { p_template_id: string }
        Returns: undefined
      }
      deactivate_workflow_rule: {
        Args: { p_rule_id: string }
        Returns: undefined
      }
      decide_employee_change_request: {
        Args: {
          p_action: string
          p_decision_reason?: string
          p_request_id: string
        }
        Returns: undefined
      }
      decide_probation_outcome: {
        Args: {
          p_effective_date: string
          p_new_end_date?: string
          p_outcome: string
          p_period_id: string
          p_reason?: string
        }
        Returns: Json
      }
      delete_cancelled_shifts: {
        Args: { p_reason?: string; p_shift_ids: string[] }
        Returns: Json
      }
      delete_payslip_deduction: {
        Args: { p_deduction_id: string }
        Returns: Json
      }
      delete_pending_document: {
        Args: { p_document_id: string }
        Returns: undefined
      }
      delete_timesheet_entry: { Args: { p_entry_id: string }; Returns: Json }
      delete_tips_pool: { Args: { p_pool_id: string }; Returns: Json }
      employee_missing_key_documents: {
        Args: { p_employee_id: string }
        Returns: string[]
      }
      entity_admin_self_approval_enabled: { Args: never; Returns: boolean }
      evaluate_workflow_condition: {
        Args: {
          p_condition_field: string
          p_condition_operator: string
          p_condition_value: string
          p_event_data: Json
        }
        Returns: boolean
      }
      evaluate_workflow_rules: {
        Args: {
          p_entity_id: string
          p_event_data: Json
          p_module: string
          p_source_record_id: string
          p_source_table: string
          p_trigger_event: string
        }
        Returns: undefined
      }
      export_audit_log: {
        Args: {
          p_action?: string
          p_actor_id?: string
          p_after?: string
          p_before?: string
          p_employee_id?: string
          p_entity_id?: string
          p_location_id?: string
          p_module?: string
          p_table_name?: string
        }
        Returns: {
          action: string
          changed_at: string
          changed_by: string
          employee_id: string
          entity_id: string
          id: string
          location_id: string
          new_value: Json
          old_value: Json
          record_id: string
          table_name: string
        }[]
      }
      generate_shifts_from_templates: {
        Args: {
          p_location_id: string
          p_period_end: string
          p_period_start: string
        }
        Returns: number
      }
      get_application_interview_feedback: {
        Args: { p_application_id: string }
        Returns: {
          cancelled_at: string
          competency_ratings: Json
          concerns: string
          feedback_id: string
          feedback_status: string
          feedback_visible: boolean
          interview_id: string
          interviewer_id: string
          interviewer_name: string
          notes: string
          outcome: string
          recommendation: string
          reopen_reason: string
          reopened_at: string
          round_closed: boolean
          round_closed_at: string
          round_closed_by_name: string
          round_closed_reason: string
          round_required_count: number
          round_revealed: boolean
          round_submitted_count: number
          scheduled_at: string
          sequence: number
          stage_id: string
          stage_name: string
          strengths: string
          submitted_at: string
        }[]
      }
      get_attendance_exceptions: {
        Args: {
          p_location_id: string
          p_period_end: string
          p_period_start: string
        }
        Returns: {
          clock_in_at: string
          clock_out_at: string
          employee_id: string
          employee_name: string
          exception_type: string
          record_id: string
          shift_date: string
          shift_id: string
        }[]
      }
      get_audit_log: {
        Args: {
          p_action?: string
          p_actor_id?: string
          p_after?: string
          p_before?: string
          p_employee_id?: string
          p_entity_id?: string
          p_limit?: number
          p_location_id?: string
          p_module?: string
          p_table_name?: string
        }
        Returns: {
          action: string
          changed_at: string
          changed_by: string
          employee_id: string
          entity_id: string
          id: string
          location_id: string
          new_value: Json
          old_value: Json
          record_id: string
          table_name: string
        }[]
      }
      get_document_expiry_detail: {
        Args: { p_bucket?: string; p_entity_id?: string }
        Returns: {
          doc_type: Database["public"]["Enums"]["document_type"]
          employee_id: string
          employee_name: string
          expiry_date: string
        }[]
      }
      get_document_requirements_for_employee: {
        Args: { p_employee_id?: string }
        Returns: {
          created_at: string
          doc_type: Database["public"]["Enums"]["document_type"]
          document_expiry_date: string
          document_id: string
          document_review_status: string
          document_upload_method: string
          document_uploaded_by: string
          employee_id: string
          id: string
          is_restricted: boolean
          status: string
          updated_at: string
          waived_at: string
          waived_reason: string
        }[]
      }
      get_documents_for_review: {
        Args: { p_entity_id: string }
        Returns: {
          archived_at: string
          archived_by: string
          created_at: string
          doc_type: Database["public"]["Enums"]["document_type"]
          employee_id: string
          employee_name: string
          expiry_date: string
          id: string
          is_current: boolean
          notes: string
          redacted: boolean
          rejection_reason: string
          review_status: string
          reviewed_at: string
          reviewed_by: string
          storage_path: string
          submitted_at: string
          submitted_by: string
          supersedes_document_id: string
          updated_at: string
          version_number: number
        }[]
      }
      get_employee_compensation: {
        Args: { p_employee_id: string }
        Returns: Json
      }
      get_employee_completeness: {
        Args: { p_employee_id: string }
        Returns: Json
      }
      get_entity_dependency_summary: {
        Args: { p_entity_id: string; p_location_id: string }
        Returns: Json
      }
      get_immigration_case: { Args: { p_employee_id: string }; Returns: Json }
      get_interview_detail: { Args: { p_interview_id: string }; Returns: Json }
      get_location_attendance_overview: {
        Args: {
          p_location_id: string
          p_period_end: string
          p_period_start: string
        }
        Returns: {
          default_payable_minutes: number
          employee_id: string
          final_payable_minutes: number
          payable_status: string
          pending_adjustment: boolean
          planned_minutes: number
          shift_date: string
          shift_id: string
        }[]
      }
      get_my_attendance: {
        Args: { p_period_end: string; p_period_start: string }
        Returns: {
          attendance_id: string
          business_date: string
          clock_in_at: string
          clock_out_at: string
          corrected: boolean
          correction_reason: string
          late_minutes: number
          location_id: string
          location_name: string
          planned_end: string
          planned_start: string
          shift_id: string
          status: string
          worked_minutes: number
        }[]
      }
      get_my_availability: { Args: never; Returns: Json }
      get_my_clock_status: { Args: never; Returns: Json }
      get_my_contract: { Args: never; Returns: Json }
      get_my_immigration: { Args: never; Returns: Json }
      get_my_interviews: {
        Args: never
        Returns: {
          candidate_name: string
          feedback_status: string
          format: string
          interview_id: string
          meeting_location: string
          position_title: string
          scheduled_at: string
          stage_name: string
          state: string
        }[]
      }
      get_my_job_description: { Args: never; Returns: Json }
      get_my_notifications: {
        Args: { p_before?: string; p_limit?: number; p_unread_only?: boolean }
        Returns: {
          created_at: string
          id: string
          message: string
          notification_type: string
          priority: string
          read_at: string
          resolved_at: string
          target_id: string
          target_type: string
          title: string
        }[]
      }
      get_my_onboarding: { Args: never; Returns: Json }
      get_my_payslip: { Args: { p_payslip_id: string }; Returns: Json }
      get_my_payslips: {
        Args: never
        Returns: {
          currency: string
          gross_pay: number
          is_revision: boolean
          net_pay: number
          payroll_run_id: string
          payslip_id: string
          period_end: string
          period_start: string
          published_at: string
          run_status: string
          superseded: boolean
          total_deductions: number
          version: number
        }[]
      }
      get_offboarding_case: { Args: { p_case_id: string }; Returns: Json }
      get_onboarding_workspace: {
        Args: { p_instance_id: string }
        Returns: Json
      }
      get_owner_dashboard_kpis: {
        Args: { p_entity_id?: string }
        Returns: Json
      }
      get_payroll_payslip: { Args: { p_payslip_id: string }; Returns: Json }
      get_scheduling_setup: { Args: { p_entity_id: string }; Returns: Json }
      get_workflow_rules: {
        Args: { p_entity_id?: string; p_module?: string }
        Returns: {
          action_message_template: string
          action_target_role: Database["public"]["Enums"]["user_role"] | null
          action_type: string
          activated_at: string | null
          condition_field: string | null
          condition_operator: string | null
          condition_value: string | null
          created_at: string
          created_by: string | null
          deactivated_at: string | null
          entity_id: string
          id: string
          is_active: boolean
          is_starter: boolean
          module: string
          name: string
          supersedes_rule_id: string | null
          trigger_event: string
          updated_at: string
          version_number: number
        }[]
        SetofOptions: {
          from: "*"
          to: "workflow_rules"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_workflow_runs: {
        Args: { p_entity_id?: string; p_limit?: number; p_rule_id?: string }
        Returns: {
          details: Json | null
          entity_id: string
          event_type: string
          id: string
          ran_at: string
          result: string
          rule_id: string
          source_record_id: string
          source_table: string
        }[]
        SetofOptions: {
          from: "*"
          to: "workflow_runs"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_wps_export_readiness: {
        Args: { p_payroll_run_id: string }
        Returns: {
          employee_id: string
          employee_name: string
          missing_bank_iban: boolean
          missing_bank_name: boolean
          missing_labor_card_no: boolean
          net_pay: number
        }[]
      }
      grant_leave_balance: {
        Args: {
          p_days: number
          p_employee_id: string
          p_leave_type_id: string
          p_reason: string
        }
        Returns: undefined
      }
      has_interview_assignments: { Args: never; Returns: boolean }
      immigration_cost_summary: {
        Args: { p_entity_id: string; p_from?: string; p_to?: string }
        Returns: Json
      }
      interview_feedback_status_for: {
        Args: { p_interview_id: string }
        Returns: string
      }
      interview_state_for: {
        Args: {
          p_cancelled_at: string
          p_feedback_status: string
          p_scheduled_at: string
        }
        Returns: string
      }
      interview_visibility_window_days: { Args: never; Returns: number }
      interviewer_can_access_candidate_file: {
        Args: { p_candidate_id: string }
        Returns: boolean
      }
      is_active_employee: { Args: { p_employee_id: string }; Returns: boolean }
      is_active_user: { Args: never; Returns: boolean }
      is_interview_round_revealed: {
        Args: { p_application_id: string; p_stage_id: string }
        Returns: boolean
      }
      is_interview_within_visibility_window: {
        Args: { p_feedback_status: string; p_scheduled_at: string }
        Returns: boolean
      }
      is_payroll_run_published: {
        Args: { p_payroll_run_id: string }
        Returns: boolean
      }
      is_restricted_doc_type: {
        Args: { p_doc_type: Database["public"]["Enums"]["document_type"] }
        Returns: boolean
      }
      issue_onboarding_invitation: {
        Args: { p_instance_id: string }
        Returns: Json
      }
      list_candidate_files_for_interview: {
        Args: { p_interview_id: string }
        Returns: {
          file_type: string
          id: string
          storage_path: string
        }[]
      }
      list_immigration_cases: {
        Args: { p_entity_id: string; p_status?: string }
        Returns: Json
      }
      list_offboarding: {
        Args: { p_entity_id: string; p_status?: string }
        Returns: Json
      }
      list_onboarding: {
        Args: { p_entity_id: string; p_tab?: string }
        Returns: Json
      }
      list_probation_due: {
        Args: { p_entity_id: string; p_within_days?: number }
        Returns: Json
      }
      log_candidate_file_access: {
        Args: { p_file_id: string; p_interview_id: string }
        Returns: undefined
      }
      log_document_access: {
        Args: { p_action: string; p_document_id: string }
        Returns: undefined
      }
      mark_all_notifications_read: { Args: never; Returns: Json }
      mark_notification_read: {
        Args: { p_notification_id: string }
        Returns: Json
      }
      materialize_payroll_from_payable_shifts: {
        Args: {
          p_employee_id: string
          p_payable_shift_record_ids: string[]
          p_payroll_run_id: string
        }
        Returns: Json
      }
      my_employee_id: { Args: never; Returns: string }
      my_entity: { Args: never; Returns: string }
      my_home_location: { Args: never; Returns: string }
      my_location: { Args: never; Returns: string }
      my_role: {
        Args: never
        Returns: Database["public"]["Enums"]["user_role"]
      }
      onboarding_dashboard_summary: {
        Args: { p_entity_id: string }
        Returns: Json
      }
      onboarding_is_preboarding_self: {
        Args: { p_employee_id: string }
        Returns: boolean
      }
      onboarding_report: {
        Args: {
          p_entity_id: string
          p_from?: string
          p_kind: string
          p_to?: string
        }
        Returns: Json
      }
      onboarding_send_reminders: { Args: never; Returns: Json }
      open_immigration_case: {
        Args: { p_employee_id: string; p_notes?: string; p_track: string }
        Returns: Json
      }
      override_materialized_payable_shift: {
        Args: {
          p_new_minutes: number
          p_payable_shift_record_id: string
          p_reason: string
        }
        Returns: Json
      }
      payroll_add_adjustment: {
        Args: {
          p_amount: number
          p_code: string
          p_employee_ids: string[]
          p_kind: string
          p_mode: string
          p_period_id: string
          p_preview?: boolean
          p_reason: string
        }
        Returns: Json
      }
      payroll_add_component: {
        Args: {
          p_code: string
          p_effective_from: string
          p_effective_to: string
          p_employee_id: string
          p_kind: string
          p_label: string
          p_monthly_amount: number
          p_prorate: boolean
          p_reason: string
        }
        Returns: Json
      }
      payroll_approve: {
        Args: { p_items: Json; p_preview?: boolean }
        Returns: Json
      }
      payroll_can: {
        Args: { p_cap: string; p_entity_id: string }
        Returns: boolean
      }
      payroll_can_input_for: {
        Args: { p_employee_id: string }
        Returns: boolean
      }
      payroll_cancel_advance: {
        Args: { p_advance_id: string; p_reason: string }
        Returns: Json
      }
      payroll_confirm_hours: {
        Args: { p_employee_ids: string[]; p_period_id: string }
        Returns: Json
      }
      payroll_create_advance: {
        Args: {
          p_amount: number
          p_disbursed_on: string
          p_employee_id: string
          p_instalments: number
          p_method: string
          p_reason: string
          p_repayment_start: string
        }
        Returns: Json
      }
      payroll_create_correction: {
        Args: { p_reason: string; p_record_id: string }
        Returns: Json
      }
      payroll_create_export: { Args: { p_record_ids: string[] }; Returns: Json }
      payroll_employee_entity: {
        Args: { p_employee_id: string }
        Returns: string
      }
      payroll_end_component: {
        Args: {
          p_component_id: string
          p_effective_to: string
          p_reason: string
        }
        Returns: Json
      }
      payroll_get_settings: { Args: { p_entity_id: string }; Returns: Json }
      payroll_gratuity_preview: {
        Args: { p_employee_id: string; p_last_day: string }
        Returns: Json
      }
      payroll_hours_sheet: { Args: { p_period_id: string }; Returns: Json }
      payroll_import_attendance: {
        Args: { p_employee_ids?: string[]; p_period_id: string }
        Returns: Json
      }
      payroll_my_payslip: { Args: { p_record_id: string }; Returns: Json }
      payroll_my_payslips: { Args: never; Returns: Json }
      payroll_open_off_cycle: {
        Args: { p_entity_id: string; p_label: string; p_pay_date: string }
        Returns: string
      }
      payroll_open_period: {
        Args: { p_entity_id: string; p_month: string }
        Returns: string
      }
      payroll_period_entity: { Args: { p_period_id: string }; Returns: string }
      payroll_periods_list: { Args: { p_entity_id: string }; Returns: Json }
      payroll_prepare: {
        Args: { p_employee_ids?: string[]; p_period_id: string }
        Returns: Json
      }
      payroll_publish: { Args: { p_record_ids: string[] }; Returns: Json }
      payroll_recalculate: { Args: { p_record_ids: string[] }; Returns: Json }
      payroll_record_detail: { Args: { p_record_id: string }; Returns: Json }
      payroll_record_payments: {
        Args: {
          p_failure_reason?: string
          p_items: Json
          p_method: string
          p_paid_on: string
          p_preview?: boolean
          p_reference: string
          p_request_key: string
          p_status: string
        }
        Returns: Json
      }
      payroll_report: {
        Args: { p_kind: string; p_period_id: string }
        Returns: Json
      }
      payroll_return_to_draft: {
        Args: { p_reason: string; p_record_ids: string[] }
        Returns: Json
      }
      payroll_save_settings: {
        Args: { p: Json; p_effective_from: string; p_entity_id: string }
        Returns: Json
      }
      payroll_set_compensation: {
        Args: {
          p_basic_monthly: number
          p_effective_from: string
          p_employee_id: string
          p_hourly_rate: number
          p_overtime_eligible: boolean
          p_pay_type: string
          p_reason: string
        }
        Returns: Json
      }
      payroll_set_hours: {
        Args: {
          p_confirm?: boolean
          p_employee_id: string
          p_holiday: number
          p_night_overtime: number
          p_notes?: string
          p_overtime: number
          p_period_id: string
          p_regular: number
        }
        Returns: Json
      }
      payroll_set_last_working_date: {
        Args: { p_date: string; p_employee_id: string; p_reason: string }
        Returns: Json
      }
      payroll_set_permission: {
        Args: {
          p_entity_id: string
          p_preset: string
          p_single_step: boolean
          p_user_id: string
        }
        Returns: Json
      }
      payroll_set_role_points: {
        Args: { p_points: number; p_position_id: string }
        Returns: undefined
      }
      payroll_submit_for_review: {
        Args: { p_record_ids: string[] }
        Returns: Json
      }
      payroll_tip_confirm: {
        Args: {
          p_amount: number
          p_employee_ids: string[]
          p_end: string
          p_location_id: string
          p_method: string
          p_notes?: string
          p_period_id: string
          p_settlement: string
          p_start: string
        }
        Returns: Json
      }
      payroll_tip_preview: {
        Args: {
          p_amount: number
          p_employee_ids: string[]
          p_end: string
          p_location_id: string
          p_method: string
          p_period_id: string
          p_settlement: string
          p_start: string
        }
        Returns: Json
      }
      payroll_tip_void: {
        Args: { p_pool_id: string; p_reason: string }
        Returns: Json
      }
      payroll_void_adjustment: {
        Args: { p_adjustment_id: string; p_reason: string }
        Returns: Json
      }
      payroll_workspace: { Args: { p_period_id: string }; Returns: Json }
      propose_attendance_adjustment: {
        Args: {
          p_payable_shift_record_id: string
          p_proposed_minutes: number
          p_reason: string
        }
        Returns: Json
      }
      propose_auto_schedule: {
        Args: {
          p_entity_id: string
          p_location_ids?: string[]
          p_period_end: string
          p_period_start: string
        }
        Returns: Json
      }
      propose_data_retention_policy: {
        Args: {
          p_disposal_method: string
          p_entity_id?: string
          p_legal_basis: string
          p_retention_years: number
          p_table_name: string
        }
        Returns: string
      }
      publish_schedule_period: {
        Args: {
          p_location_id: string
          p_period_end: string
          p_period_start: string
        }
        Returns: number
      }
      raise_onboarding_exception: {
        Args: {
          p_description: string
          p_due_date?: string
          p_instance_id: string
          p_is_blocking?: boolean
          p_owner_role?: string
          p_type: string
        }
        Returns: Json
      }
      record_day_one_outcome: {
        Args: {
          p_instance_id: string
          p_new_start_date?: string
          p_outcome: string
          p_reason?: string
        }
        Returns: Json
      }
      record_payslip_deduction: {
        Args: {
          p_amount: number
          p_deduction_type: string
          p_employee_id: string
          p_notes?: string
          p_payroll_run_id: string
        }
        Returns: Json
      }
      record_probation_review: {
        Args: {
          p_comments: string
          p_period_id: string
          p_ratings?: Json
          p_recommendation: string
        }
        Returns: Json
      }
      record_timesheet_entry: {
        Args: {
          p_employee_id: string
          p_holiday_hours?: number
          p_notes?: string
          p_overtime_hours?: number
          p_payroll_run_id: string
          p_regular_hours?: number
        }
        Returns: Json
      }
      record_tips_pool: {
        Args: {
          p_location_id: string
          p_notes?: string
          p_payroll_run_id: string
          p_total_amount?: number
        }
        Returns: Json
      }
      reissue_onboarding_invitation: {
        Args: { p_instance_id: string; p_new_email?: string; p_reason: string }
        Returns: Json
      }
      reject_attendance_adjustment: {
        Args: { p_adjustment_id: string; p_reason: string }
        Returns: Json
      }
      reject_document: {
        Args: { p_document_id: string; p_reason: string }
        Returns: undefined
      }
      renewal_supersedes_owned_by: {
        Args: { p_supersedes_document_id: string }
        Returns: boolean
      }
      reopen_interview_feedback: {
        Args: { p_interview_id: string; p_reason: string }
        Returns: undefined
      }
      replace_onboarding_template: {
        Args: {
          p_description: string
          p_employment_types?: Database["public"]["Enums"]["employment_type"][]
          p_name: string
          p_position_ids?: string[]
          p_tasks: Json
          p_template_id: string
        }
        Returns: string
      }
      replace_schedule_template: {
        Args: {
          p_break_minutes: number
          p_day_of_week: number
          p_effective_end_date: string
          p_effective_start_date: string
          p_end_time: string
          p_position_id: string
          p_start_time: string
          p_template_id: string
        }
        Returns: string
      }
      request_shift_swap: {
        Args: { p_notes?: string; p_shift_id: string }
        Returns: string
      }
      requisition_entity_for_interview: {
        Args: { p_interview_id: string }
        Returns: string
      }
      reschedule_interview: {
        Args: {
          p_format?: string
          p_interview_id: string
          p_meeting_location?: string
          p_new_interviewer_id?: string
          p_new_scheduled_at: string
          p_reason?: string
        }
        Returns: string
      }
      resolve_onboarding_exception: {
        Args: {
          p_cancel?: boolean
          p_exception_id: string
          p_resolution: string
        }
        Returns: Json
      }
      review_onboarding_compensation: {
        Args: { p_decision: string; p_instance_id: string; p_reason?: string }
        Returns: Json
      }
      review_onboarding_section: {
        Args: {
          p_decision: string
          p_instance_id: string
          p_reason?: string
          p_section: string
        }
        Returns: Json
      }
      review_onboarding_task: {
        Args: { p_decision: string; p_reason?: string; p_task_id: string }
        Returns: Json
      }
      run_document_expiry_workflow_check: { Args: never; Returns: number }
      run_leave_accrual: {
        Args: { p_leave_type_id: string; p_period_key: string }
        Returns: number
      }
      run_payroll_calculation: {
        Args: { p_payroll_run_id: string }
        Returns: undefined
      }
      save_interview_feedback_draft: {
        Args: {
          p_competency_ratings?: Json
          p_concerns?: string
          p_interview_id: string
          p_notes?: string
          p_recommendation?: string
          p_strengths?: string
        }
        Returns: string
      }
      save_my_availability: { Args: { p_days: Json }; Returns: Json }
      save_my_onboarding_profile: { Args: { p: Json }; Returns: Json }
      save_my_payment_details: {
        Args: {
          p_account_name: string
          p_bank_name: string
          p_iban: string
          p_method: string
          p_routing_code?: string
        }
        Returns: Json
      }
      seed_default_onboarding_template: {
        Args: { p_entity_id: string }
        Returns: string
      }
      seed_document_requirements_for_employee: {
        Args: {
          p_doc_types: Database["public"]["Enums"]["document_type"][]
          p_employee_id: string
        }
        Returns: number
      }
      seed_payable_shift_records: {
        Args: {
          p_location_id: string
          p_period_end: string
          p_period_start: string
        }
        Returns: Json
      }
      set_employee_compensation: {
        Args: {
          p_employee_id: string
          p_holiday_multiplier?: number
          p_overtime_multiplier?: number
          p_pay_rate: number
          p_pay_type: string
          p_reason?: string
        }
        Returns: undefined
      }
      set_employee_numbering: {
        Args: {
          p_entity_id: string
          p_next_value: number
          p_pad_width: number
          p_prefix: string
        }
        Returns: undefined
      }
      set_employee_status: {
        Args: {
          p_employee_id: string
          p_new_status: Database["public"]["Enums"]["employee_status"]
          p_reason: string
        }
        Returns: undefined
      }
      set_employee_work_pattern: {
        Args: {
          p_days_off_mode: string
          p_days_per_week: number
          p_employee_id: string
          p_fixed_days_off: number[]
        }
        Returns: Json
      }
      set_entity_admin_self_approval: {
        Args: { p_enabled: boolean }
        Returns: undefined
      }
      set_immigration_step_blocking: {
        Args: { p_is_blocking: boolean; p_reason: string; p_step_id: string }
        Returns: Json
      }
      set_location_operating_hours: {
        Args: { p_hours: Json; p_location_id: string }
        Returns: undefined
      }
      set_location_staffing_needs: {
        Args: { p_location_id: string; p_needs: Json }
        Returns: number
      }
      set_onboarding_pending_compensation: {
        Args: {
          p_basic_monthly: number
          p_effective_from: string
          p_hourly_rate: number
          p_instance_id: string
          p_overtime_eligible: boolean
          p_pay_type: string
          p_reason: string
          p_variance_reason?: string
        }
        Returns: Json
      }
      set_onboarding_settings: {
        Args: { p: Json; p_entity_id: string }
        Returns: Json
      }
      stage_document_renewal: {
        Args: {
          p_current_document_id: string
          p_expiry_date?: string
          p_file_extension: string
          p_notes?: string
          p_upload_method?: string
        }
        Returns: Json
      }
      stage_document_upload: {
        Args: {
          p_doc_type: Database["public"]["Enums"]["document_type"]
          p_employee_id: string
          p_expiry_date?: string
          p_file_extension: string
          p_notes?: string
          p_upload_method?: string
        }
        Returns: Json
      }
      stage_my_onboarding_document: {
        Args: {
          p_doc_type: Database["public"]["Enums"]["document_type"]
          p_expiry_date?: string
          p_file_extension: string
          p_notes?: string
        }
        Returns: Json
      }
      start_offboarding: {
        Args: {
          p_employee_id: string
          p_initiated_by: string
          p_last_working_date: string
          p_leaving_uae?: boolean
          p_notice_date: string
          p_notice_shortfall_reason?: string
          p_reason: string
          p_source_exception_id?: string
          p_type: string
        }
        Returns: Json
      }
      start_offboarding_settlement: {
        Args: { p_case_id: string; p_pay_date?: string }
        Returns: Json
      }
      start_onboarding_direct_hire: {
        Args: {
          p_email: string
          p_employment_type: string
          p_entity_id: string
          p_full_name: string
          p_gender: string
          p_home_location_id: string
          p_phone: string
          p_position_id: string
          p_reason: string
          p_reporting_manager_employee_id: string
          p_start_date: string
        }
        Returns: Json
      }
      start_onboarding_for_employee: {
        Args: {
          p_employee_id: string
          p_reason: string
          p_reporting_manager_employee_id: string
        }
        Returns: Json
      }
      start_onboarding_from_offer: {
        Args: { p_offer_id: string; p_reporting_manager_employee_id?: string }
        Returns: Json
      }
      submit_document_renewal: {
        Args: {
          p_current_document_id: string
          p_expiry_date?: string
          p_notes?: string
          p_storage_path: string
        }
        Returns: string
      }
      submit_interview_feedback: {
        Args: { p_interview_id: string }
        Returns: undefined
      }
      submit_onboarding_section: {
        Args: { p_instance_id: string; p_section: string }
        Returns: Json
      }
      suggest_immigration_track: {
        Args: { p_employee_id: string }
        Returns: string
      }
      test_workflow_rule: {
        Args: { p_rule_id: string; p_sample_event: Json }
        Returns: string
      }
      uat_fixtures_refresh: { Args: never; Returns: Json }
      uat_purge_seed: { Args: never; Returns: Json }
      unread_notification_count: { Args: never; Returns: number }
      update_employee_details: {
        Args: { p_changes: Json; p_employee_id: string }
        Returns: undefined
      }
      update_immigration_case: {
        Args: { p: Json; p_case_id: string }
        Returns: Json
      }
      update_immigration_step: {
        Args: {
          p_due_date?: string
          p_expiry_date?: string
          p_fee_amount?: number
          p_fee_paid_by?: string
          p_notes?: string
          p_reference?: string
          p_status: string
          p_step_id: string
        }
        Returns: Json
      }
      update_offboarding_dates: {
        Args: {
          p_case_id: string
          p_expected_version: number
          p_last_working_date: string
          p_notice_date: string
          p_notice_shortfall_reason?: string
          p_reason: string
        }
        Returns: Json
      }
      update_onboarding_setup: {
        Args: {
          p: Json
          p_expected_version: number
          p_instance_id: string
          p_reason: string
        }
        Returns: Json
      }
      upsert_onboarding_policy: {
        Args: {
          p_body: string
          p_entity_id: string
          p_policy_key: string
          p_title: string
          p_version: string
        }
        Returns: string
      }
      upsert_position: {
        Args: {
          p_department: string
          p_description: string
          p_entity_id: string
          p_position_id: string
          p_title: string
        }
        Returns: string
      }
      verify_payment_details: {
        Args: {
          p_decision: string
          p_payment_details_id: string
          p_reason?: string
        }
        Returns: Json
      }
      waive_document_requirement: {
        Args: { p_reason: string; p_requirement_id: string }
        Returns: undefined
      }
      waive_onboarding_task: {
        Args: { p_reason: string; p_task_id: string }
        Returns: Json
      }
      withdraw_onboarding: {
        Args: { p_instance_id: string; p_reason: string }
        Returns: Json
      }
      workflow_trigger_catalog: { Args: never; Returns: Json }
    }
    Enums: {
      document_type:
        | "passport"
        | "visa"
        | "labor_card"
        | "health_card"
        | "emirates_id"
        | "offer_letter"
        | "contract"
        | "other"
        | "bank_payment_document"
        | "compensation_document"
      employee_status: "candidate" | "pre_boarding" | "active" | "inactive"
      employment_type: "full_time" | "part_time" | "on_call" | "seasonal"
      user_role: "owner" | "entity_admin" | "location_manager" | "staff"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      document_type: [
        "passport",
        "visa",
        "labor_card",
        "health_card",
        "emirates_id",
        "offer_letter",
        "contract",
        "other",
        "bank_payment_document",
        "compensation_document",
      ],
      employee_status: ["candidate", "pre_boarding", "active", "inactive"],
      employment_type: ["full_time", "part_time", "on_call", "seasonal"],
      user_role: ["owner", "entity_admin", "location_manager", "staff"],
    },
  },
} as const
