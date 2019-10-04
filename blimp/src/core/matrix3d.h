#pragma once

#include "vector2d.h"
#include "vector3d.h"

struct Matrix3D
{
public:
	union {
		float m[9];
		struct
		{
			float m00, m01, m02, m10, m11, m12, m20, m21, m22;
		};
	};

	Matrix3D()
		: m00(1.0f), m01(0.0f), m02(0.0f),
		  m10(0.0f), m11(1.0f), m12(0.0f),
		  m20(0.0f), m21(0.0f), m22(1.0f) {}

	Matrix3D(float m00, float m01, float m02,
			 float m10, float m11, float m12,
			 float m20, float m21, float m22)
		: m00(m00), m01(m01), m02(m02),
		  m10(m10), m11(m11), m12(m12),
		  m20(m20), m21(m21), m22(m22) {}

	inline void transpose();

	inline void set_translation(const Vector2D &translation);
	inline void set_rotation_angle(float angle);

	inline Vector2D translation() const;
	inline float rotation_angle() const;
	inline Vector2D scale() const;

	inline static Matrix3D translation_matrix3d(const Vector2D &translation);
	inline static Matrix3D rotation_matrix3d(float angleInRad);
	inline static Matrix3D scale_matrix3d(const Vector2D &scale);
	inline static Matrix3D identity();
};

inline void Matrix3D::transpose()
{
	Matrix3D originalMatrix = *this;
	this->m00 = originalMatrix.m00;
	this->m01 = originalMatrix.m10;
	this->m11 = originalMatrix.m11;
	this->m12 = originalMatrix.m21;
	this->m20 = originalMatrix.m02;
	this->m21 = originalMatrix.m12;
	this->m22 = originalMatrix.m22;
}

inline Vector3D operator*(const Matrix3D &mat, const Vector3D &vec);
inline Matrix3D operator*(const Matrix3D &mat1, const Matrix3D &mat2);
inline Vector2D operator*(const Matrix3D &mat, const Vector2D &vec);

void Matrix3D::set_translation(const Vector2D &translation)
{
	this->m02 = translation.x;
	this->m12 = translation.y;
}

inline void Matrix3D::set_rotation_angle(float angle)
{
	Vector2D scale = this->scale();
	Matrix3D scaleMat = Matrix3D::scale_matrix3d(scale);
	Vector2D translation = this->translation();
	Matrix3D transMat = Matrix3D::translation_matrix3d(translation);
	float rad = (float)(angle * M_PI / 180.0f);
	Matrix3D rotMat = Matrix3D::rotation_matrix3d(rad);
	(*this) = transMat * (rotMat * scaleMat);
}

Vector2D Matrix3D::translation() const
{
	return Vector2D(this->m02, this->m12);
}

inline float Matrix3D::rotation_angle() const
{
	return float(atan2(-m01, m00) * 180.0f / M_PI);
}

Vector2D Matrix3D::scale() const
{
	Vector2D sx = Vector2D(m00, m01);
	Vector2D sy = Vector2D(m10, m11);
	/*return Vector2D((m00 >= 0 ? 1 : -1) * sx.GetLength(),
					(m11 >= 0 ? 1 : -1) * sy.GetLength());*/
	return Vector2D(sx.length(),
					sy.length());
}

Matrix3D Matrix3D::translation_matrix3d(const Vector2D &translation)
{
	return Matrix3D(1, 0, translation.x,
					0, 1, translation.y,
					0, 0, 1);
}

Matrix3D Matrix3D::rotation_matrix3d(float angleInRad)
{
	return Matrix3D((float)cos(angleInRad), (float)-sin(angleInRad), 0.0f,
					(float)sin(angleInRad), (float)cos(angleInRad), 0.0f,
					0.0f, 0.0f, 1.0f);
}

Matrix3D Matrix3D::scale_matrix3d(const Vector2D &scale)
{
	return Matrix3D(scale.x, 0, 0,
					0, scale.y, 0,
					0, 0, 1);
}

Matrix3D Matrix3D::identity()
{
	return Matrix3D(1.0f, 0.0f, 0.0f,
					0.0f, 1.0f, 0.0f,
					0.0f, 0.0f, 1.0f);
}

inline Vector3D operator*(const Matrix3D &mat, const Vector3D &vec)
{
	return Vector3D(mat.m00 * vec.x + mat.m01 * vec.y + mat.m02 * vec.z,
					mat.m10 * vec.x + mat.m11 * vec.y + mat.m12 * vec.z,
					mat.m20 * vec.x + mat.m21 * vec.y + mat.m22 * vec.z);
}

inline Matrix3D operator*(const Matrix3D &mat1, const Matrix3D &mat2)
{
	return Matrix3D(
		mat1.m00 * mat2.m00 + mat1.m01 * mat2.m10 + mat1.m02 * mat2.m20,
		mat1.m00 * mat2.m01 + mat1.m01 * mat2.m11 + mat1.m02 * mat2.m21,
		mat1.m00 * mat2.m02 + mat1.m01 * mat2.m12 + mat1.m02 * mat2.m22,
		mat1.m10 * mat2.m00 + mat1.m11 * mat2.m10 + mat1.m12 * mat2.m20,
		mat1.m10 * mat2.m01 + mat1.m11 * mat2.m11 + mat1.m12 * mat2.m21,
		mat1.m10 * mat2.m02 + mat1.m11 * mat2.m12 + mat1.m12 * mat2.m22,
		mat1.m20 * mat2.m00 + mat1.m21 * mat2.m10 + mat1.m22 * mat2.m20,
		mat1.m20 * mat2.m01 + mat1.m21 * mat2.m11 + mat1.m22 * mat2.m21,
		mat1.m20 * mat2.m02 + mat1.m21 * mat2.m12 + mat1.m22 * mat2.m22);
}

inline Vector2D operator*(const Matrix3D &mat, const Vector2D &vec)
{
	return Vector2D(mat.m00 * vec.x + mat.m01 * vec.y + mat.m02,
					mat.m10 * vec.x + mat.m11 * vec.y + mat.m12);
}